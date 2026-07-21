extends Node

const TokenVerifier = preload("res://common/license/rs256_license_token.gd")

const STATE_SCHEMA_VERSION := 1
const MAX_CLOCK_SKEW_SECONDS := 300
const REQUEST_TIMEOUT_SECONDS := 10.0
const REQUEST_BODY_LIMIT := 65536

var _config: Dictionary = {}
var _state: Dictionary = {}
var _fatal_error: Dictionary = {}
var _session_ticks_msec := 0
var _last_online_result := "never"
var _last_online_age_seconds: Variant = null
var _online_valid := false
var _status_override := ""


func configure(config: Dictionary) -> Dictionary:
    _config = config.duplicate(true)
    _fatal_error = {}
    _last_online_result = "never"
    _last_online_age_seconds = null
    _online_valid = false
    _status_override = ""
    var validation := _validate_config(_config)
    if not validation.ok:
        return _set_fatal("config", validation.error_code)

    var loaded := _load_state(String(_config.state_path))
    if not loaded.ok:
        return _set_fatal("storage", loaded.error_code)
    _state = loaded.state
    _session_ticks_msec = Time.get_ticks_msec()
    if not _state.jwt.is_empty() and int(_state.session_anchor_utc) <= 0:
        return _set_fatal("storage", "missing_session_anchor")
    return {"ok": true}


func configure_from_path(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return _set_fatal("config", "config_missing")
    var parsed: Variant = _parse_json(FileAccess.get_file_as_string(path))
    if typeof(parsed) != TYPE_DICTIONARY:
        return _set_fatal("config", "config_invalid")
    return configure(parsed)


func get_snapshot() -> Dictionary:
    if not _fatal_error.is_empty():
        return {"ok": false, "status": "invalid_token", "fatal": _fatal_error.duplicate(true)}
    if _state.is_empty():
        return {"ok": false, "status": "invalid_token", "fatal": {"kind": "config", "code": "not_configured"}}
    if bool(_state.revoked):
        return _snapshot("revoked", "never", null, null)
    if String(_state.jwt).is_empty():
        if _status_override == "invalid_token":
            return _snapshot("invalid_token", _last_online_result, _last_online_age_seconds, null)
        return _snapshot("not_activated", "never", null, null)

    var effective := _effective_now()
    if not effective.ok:
        return {"ok": false, "status": "invalid_token", "fatal": effective.fatal}
    var verified := _verify_cached_token(int(effective.now))
    if not verified.ok:
        var expired := TokenVerifier.verify(String(_state.jwt), String(_config.public_key_path), _config.allowed_kids, int(effective.now), false, true)
        if expired.ok and int(expired.claims.exp) <= int(effective.now):
            return _snapshot("offline_grace_expired", _last_online_result, _last_online_age_seconds, 0)
        return _snapshot("invalid_token", "never", null, null)
    var claims: Dictionary = verified.claims
    var remaining: int = max(0, int(claims.exp) - int(effective.now))
    var state_name := "online_valid" if _online_valid else "offline_grace_valid"
    return _snapshot(state_name, _last_online_result, _last_online_age_seconds, remaining)


func activate(license_key: String) -> Dictionary:
    if typeof(license_key) != TYPE_STRING or license_key.is_empty():
        return {"ok": false, "error_type": "request", "error_code": "license_key_required"}
    return await _request_token(String(_config.issue_endpoint), {"license_key": license_key})


func refresh_online() -> Dictionary:
    if _state.is_empty() or String(_state.jwt).is_empty():
        return {"ok": false, "error_type": "request", "error_code": "not_activated"}
    return await _request_token(String(_config.verify_endpoint), {"token": String(_state.jwt)})


func revoke_local() -> Dictionary:
    if _state.is_empty():
        return _set_fatal("storage", "not_configured")
    _state.revoked = true
    var persisted := _persist_state()
    if not persisted.ok:
        return _set_fatal("storage", persisted.error_code)
    return {"ok": true}


func clear() -> Dictionary:
    if _state.is_empty():
        return {"ok": true}
    var path := String(_config.state_path)
    if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
        return _set_fatal("storage", "state_remove_failed")
    _state = _new_state()
    return {"ok": true}


func _validate_endpoint(endpoint: String) -> Dictionary:
    if endpoint.is_empty() or endpoint.contains("#") or endpoint.contains("@") or endpoint.contains(" "):
        return {"ok": false, "error_code": "endpoint_invalid"}
    if endpoint.begins_with("https://"):
        var https_authority := endpoint.trim_prefix("https://").split("/", false, 1)[0]
        if https_authority.is_empty() or https_authority.contains("://"):
            return {"ok": false, "error_code": "endpoint_invalid"}
        return {"ok": true}
    var loopback := RegEx.new()
    loopback.compile("^http://(127\\.0\\.0\\.1|\\[::1\\]):[0-9]+(?:/.*)?$")
    if loopback.search(endpoint) != null:
        return {"ok": true}
    return {"ok": false, "error_code": "endpoint_invalid"}


func _validate_config(config: Dictionary) -> Dictionary:
    if int(config.get("schema_version", -1)) != STATE_SCHEMA_VERSION:
        return {"ok": false, "error_code": "config_schema"}
    for key in ["issue_endpoint", "verify_endpoint", "public_key_path", "state_path"]:
        if not config.has(key) or typeof(config[key]) != TYPE_STRING or String(config[key]).is_empty():
            return {"ok": false, "error_code": "config_missing_%s" % key}
    if not String(config.state_path).begins_with("user://"):
        return {"ok": false, "error_code": "state_path_not_user_only"}
    for endpoint in [String(config.issue_endpoint), String(config.verify_endpoint)]:
        var endpoint_result := _validate_endpoint(endpoint)
        if not endpoint_result.ok:
            return endpoint_result
    if not config.has("allowed_kids") or typeof(config.allowed_kids) != TYPE_ARRAY or config.allowed_kids.is_empty():
        return {"ok": false, "error_code": "config_kids"}
    for kid in config.allowed_kids:
        if typeof(kid) != TYPE_STRING or kid.is_empty() or kid.length() > 64 or kid.contains("/"):
            return {"ok": false, "error_code": "config_kids"}
    if not FileAccess.file_exists(String(config.public_key_path)):
        return {"ok": false, "error_code": "public_key_missing"}
    var public_key := CryptoKey.new()
    if public_key.load(String(config.public_key_path), true) != OK:
        return {"ok": false, "error_code": "public_key_invalid"}
    return {"ok": true}


func _load_state(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"ok": true, "state": _new_state()}
    if OS.has_feature("linux") and FileAccess.get_unix_permissions(path) != 384:
        return {"ok": false, "error_code": "state_permissions_invalid"}
    var parsed: Variant = _parse_json(FileAccess.get_file_as_string(path))
    if typeof(parsed) != TYPE_DICTIONARY:
        return {"ok": false, "error_code": "state_invalid"}
    for key in ["schema_version", "jwt", "max_observed_utc", "session_anchor_utc", "revoked"]:
        if not parsed.has(key):
            return {"ok": false, "error_code": "state_invalid"}
    if not _is_integral_number(parsed.schema_version) or int(parsed.schema_version) != STATE_SCHEMA_VERSION:
        return {"ok": false, "error_code": "state_invalid"}
    if typeof(parsed.jwt) != TYPE_STRING or not _is_integral_number(parsed.max_observed_utc):
        return {"ok": false, "error_code": "state_invalid"}
    if not _is_integral_number(parsed.session_anchor_utc) or typeof(parsed.revoked) != TYPE_BOOL:
        return {"ok": false, "error_code": "state_invalid"}
    return {"ok": true, "state": parsed}


func _new_state() -> Dictionary:
    return {
        "schema_version": STATE_SCHEMA_VERSION,
        "jwt": "",
        "max_observed_utc": 0,
        "session_anchor_utc": 0,
        "revoked": false,
    }


func _parse_json(text: String) -> Variant:
    var parser := JSON.new()
    if parser.parse(text) != OK:
        return null
    return parser.data


func _is_integral_number(value: Variant) -> bool:
    if typeof(value) == TYPE_INT:
        return true
    if typeof(value) != TYPE_FLOAT or not is_finite(value):
        return false
    return value == floor(value)


func _effective_now() -> Dictionary:
    var wall := int(Time.get_unix_time_from_system())
    var floor_value := int(_state.max_observed_utc)
    var session_value := int(_state.session_anchor_utc) + int((Time.get_ticks_msec() - _session_ticks_msec) / 1000)
    if floor_value > wall + MAX_CLOCK_SKEW_SECONDS:
        return {"ok": false, "fatal": {"kind": "clock", "code": "clock_rollback_detected"}}
    var effective: int = max(wall, max(floor_value, session_value))
    return {"ok": true, "now": effective}


func _verify_cached_token(now: int) -> Dictionary:
    return TokenVerifier.verify(String(_state.jwt), String(_config.public_key_path), _config.allowed_kids, now)


func _request_token(endpoint: String, body: Dictionary) -> Dictionary:
    var endpoint_result := _validate_endpoint(endpoint)
    if not endpoint_result.ok:
        return _set_fatal("config", endpoint_result.error_code)
    var request := HTTPRequest.new()
    request.max_redirects = 0
    request.timeout = REQUEST_TIMEOUT_SECONDS
    request.body_size_limit = REQUEST_BODY_LIMIT
    request.accept_gzip = false
    add_child(request)
    var request_error := request.request(endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
    if request_error != OK:
        _last_online_result = "unreachable"
        request.queue_free()
        return {"ok": false, "error_type": "network", "error_code": "request_failed"}
    var response: Array = await request.request_completed
    request.queue_free()
    var request_result := int(response[0])
    var http_status := int(response[1])
    var response_body: PackedByteArray = response[3]

    if http_status == 401:
        _state.jwt = ""
        _online_valid = false
        _status_override = "invalid_token"
        _last_online_result = "rejected"
        var rejected_persisted := _persist_state()
        if not rejected_persisted.ok:
            return _set_fatal("storage", rejected_persisted.error_code)
        return {"ok": false, "error_type": "license", "error_code": "invalid_token"}

    if request_result != HTTPRequest.RESULT_SUCCESS:
        _last_online_result = "unreachable"
        return {"ok": false, "error_type": "network", "error_code": "request_failed"}

    if http_status >= 300 and http_status < 400:
        _last_online_result = "unreachable"
        return {"ok": false, "error_type": "network", "error_code": "redirect_rejected"}
    var parsed: Variant = JSON.parse_string(response_body.get_string_from_utf8())
    if http_status == 403 and typeof(parsed) == TYPE_DICTIONARY and parsed.get("error", "") == "revoked":
        _state.revoked = true
        var revoked_persisted := _persist_state()
        if not revoked_persisted.ok:
            return _set_fatal("storage", revoked_persisted.error_code)
        _last_online_result = "rejected"
        return {"ok": false, "error_type": "license", "error_code": "revoked"}
    if http_status < 200 or http_status >= 300 or typeof(parsed) != TYPE_DICTIONARY:
        _last_online_result = "unreachable"
        return {"ok": false, "error_type": "network", "error_code": "unexpected_response"}
    var token: Variant = parsed.get("token", null)
    if typeof(token) != TYPE_STRING or String(token).is_empty():
        _last_online_result = "rejected"
        return {"ok": false, "error_type": "license", "error_code": "invalid_token"}
    var effective := _effective_now()
    var verification_now := int(Time.get_unix_time_from_system())
    var allow_clock_recovery: bool = not effective.ok
    var verified := TokenVerifier.verify(String(token), String(_config.public_key_path), _config.allowed_kids, verification_now, allow_clock_recovery)
    if not verified.ok:
        _last_online_result = "rejected"
        if not effective.ok:
            return effective
        return {"ok": false, "error_type": "license", "error_code": "invalid_token"}
    var accepted_now := verification_now
    if allow_clock_recovery:
        if int(verified.claims.iat) < int(_state.max_observed_utc):
            return effective
        accepted_now = max(verification_now, int(verified.claims.iat))
    elif not effective.ok:
        return effective
    _last_online_result = "success"
    _last_online_age_seconds = 0
    _online_valid = true
    _status_override = ""
    _state.jwt = String(token)
    _state.max_observed_utc = accepted_now
    _state.session_anchor_utc = accepted_now
    _state.revoked = false
    var persisted := _persist_state()
    if not persisted.ok:
        return _set_fatal("storage", persisted.error_code)
    return {"ok": true, "status": "online_valid"}


func _persist_state() -> Dictionary:
    var path := String(_config.state_path)
    var temporary := "%s.tmp" % path
    var file := FileAccess.open(temporary, FileAccess.WRITE)
    if file == null:
        return {"ok": false, "error_code": "state_open_failed"}
    file.store_string(JSON.stringify(_state))
    var write_error := file.get_error()
    file.close()
    if write_error != OK:
        DirAccess.remove_absolute(temporary)
        return {"ok": false, "error_code": "state_write_failed"}
    if OS.has_feature("linux"):
        if FileAccess.set_unix_permissions(temporary, 384) != OK or FileAccess.get_unix_permissions(temporary) != 384:
            DirAccess.remove_absolute(temporary)
            return {"ok": false, "error_code": "state_permissions_failed"}
    if DirAccess.rename_absolute(temporary, path) != OK:
        DirAccess.remove_absolute(temporary)
        return {"ok": false, "error_code": "state_rename_failed"}
    if OS.has_feature("linux") and FileAccess.get_unix_permissions(path) != 384:
        return {"ok": false, "error_code": "state_permissions_failed"}
    return {"ok": true}


func _set_fatal(kind: String, code: String) -> Dictionary:
    _fatal_error = {"kind": kind, "code": code}
    return {"ok": false, "error_type": "fatal", "error_code": code}


func _snapshot(status: String, online_result: String, age: Variant, remaining: Variant) -> Dictionary:
    return {
        "ok": status == "online_valid" or status == "offline_grace_valid" or status == "not_activated",
        "status": status,
        "last_online_result": online_result,
        "last_online_age_seconds": age,
        "offline_grace_remaining_seconds": remaining,
    }
