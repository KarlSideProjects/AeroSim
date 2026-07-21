extends GutTest

const LicenseProviderScript = preload("res://common/license/license_provider.gd")


class OneShotHttpServer extends Node:
    var _server := TCPServer.new()
    var _response := PackedByteArray()
    var _close_without_response := false
    var _client: StreamPeerTCP
    var _sent_response := false

    func start(response: String, close_without_response := false) -> int:
        _response = response.to_utf8_buffer()
        _close_without_response = close_without_response
        var result := _server.listen(0, "127.0.0.1")
        if result == OK:
            set_process(true)
        return result

    func endpoint() -> String:
        return "http://127.0.0.1:%d/verify" % _server.get_local_port()

    func _process(_delta: float) -> void:
        if _client == null and _server.is_connection_available():
            _client = _server.take_connection()
        if _client == null:
            return
        _client.poll()
        if _close_without_response:
            _client.disconnect_from_host()
            _server.stop()
            set_process(false)
            return
        if not _sent_response:
            assert(_client.put_data(_response) == OK)
            _sent_response = true

    func _exit_tree() -> void:
        if _client != null:
            _client.disconnect_from_host()
        _server.stop()


var state_path := "user://aerosim-license-provider-test.json"
var providers: Array[Node] = []


func after_each() -> void:
    for provider in providers:
        provider.queue_free()
    providers.clear()
    DirAccess.remove_absolute(state_path)
    DirAccess.remove_absolute("%s.tmp" % state_path)


func _provider() -> Node:
    var provider: Node = LicenseProviderScript.new()
    add_child(provider)
    providers.append(provider)
    return provider


func _config() -> Dictionary:
    return {
        "schema_version": 1,
        "issue_endpoint": "https://license.example.test/issue",
        "verify_endpoint": "https://license.example.test/verify",
        "public_key_path": "res://config/license_public_key.pem",
        "allowed_kids": ["ubuntu-2026"],
        "state_path": state_path,
    }


func _write_state(text: String) -> void:
    var file := FileAccess.open(state_path, FileAccess.WRITE)
    file.store_string(text)
    file.close()
    if OS.has_feature("linux"):
        assert_eq(FileAccess.set_unix_permissions(state_path, 384), OK)


func _http_server(response := "", close_without_response := false) -> OneShotHttpServer:
    var server := OneShotHttpServer.new()
    add_child(server)
    autofree(server)
    assert_eq(server.start(response, close_without_response), OK)
    return server


func test_endpoint_policy_is_numeric_loopback_or_https_only() -> void:
    var provider := _provider()
    for endpoint in [
        "http://localhost:8080/issue",
        "http://0.0.0.0:8080/issue",
        "http://127.0.0.2:8080/issue",
        "http://user:pass@127.0.0.1:8080/issue",
        "http://127.0.0.1:8080/issue#fragment",
        "http://[::2]:8080/issue",
    ]:
        assert_false(provider._validate_endpoint(endpoint).ok, endpoint)
    assert_true(provider._validate_endpoint("https://license.example.test/issue").ok)
    assert_true(provider._validate_endpoint("http://127.0.0.1:8080/issue").ok)
    assert_true(provider._validate_endpoint("http://[::1]:8080/issue").ok)


func test_missing_state_is_not_activated_and_snapshot_is_redacted() -> void:
    var provider := _provider()
    assert_true(provider.configure(_config()).ok)
    var snapshot: Dictionary = provider.get_snapshot()
    assert_eq(snapshot.status, "not_activated")
    for secret_field in ["jwt", "token", "claims", "sub", "jti", "license_key", "secret"]:
        assert_false(snapshot.has(secret_field), secret_field)


func test_corrupt_state_is_fatal() -> void:
    _write_state("{not-json")
    var provider := _provider()
    var configured: Dictionary = provider.configure(_config())
    assert_false(configured.ok)
    assert_eq(configured.error_type, "fatal")
    assert_eq(provider.get_snapshot().status, "invalid_token")


func test_state_with_wrong_permissions_is_fatal() -> void:
    if not OS.has_feature("linux"):
        pass_test("0600 is Linux-specific")
        return
    _write_state(JSON.stringify({
        "schema_version": 1,
        "jwt": "",
        "max_observed_utc": 0,
        "session_anchor_utc": 0,
        "revoked": false,
    }))
    assert_eq(FileAccess.set_unix_permissions(state_path, 420), OK)
    var provider := _provider()
    var configured: Dictionary = provider.configure(_config())
    assert_false(configured.ok)
    assert_eq(configured.error_code, "state_permissions_invalid")


func test_token_without_session_anchor_is_fatal() -> void:
    _write_state(JSON.stringify({
        "schema_version": 1,
        "jwt": "redacted-test-token",
        "max_observed_utc": 1700000000,
        "session_anchor_utc": 0,
        "revoked": false,
    }))
    var provider := _provider()
    var configured: Dictionary = provider.configure(_config())
    assert_false(configured.ok)
    assert_eq(configured.error_code, "missing_session_anchor")


func test_unreachable_loopback_refresh_reports_request_failure_without_parsing_an_empty_body() -> void:
    _write_state(JSON.stringify({
        "schema_version": 1,
        "jwt": "redacted-test-token",
        "max_observed_utc": 1700000000,
        "session_anchor_utc": 1700000000,
        "revoked": false,
    }))
    var config := _config()
    var server := _http_server("", true)
    config.verify_endpoint = server.endpoint()
    var provider := _provider()
    assert_true(provider.configure(config).ok)

    var refreshed: Dictionary = await provider.refresh_online()

    assert_false(refreshed.ok)
    assert_eq(refreshed.error_type, "network")
    assert_eq(refreshed.error_code, "request_failed")


func test_oversized_unauthorized_response_invalidates_cached_license() -> void:
    _write_state(JSON.stringify({
        "schema_version": 1,
        "jwt": "redacted-test-token",
        "max_observed_utc": 1700000000,
        "session_anchor_utc": 1700000000,
        "revoked": false,
    }))
    var oversized_body := "x".repeat(65537)
    var response := "HTTP/1.1 401 Unauthorized\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [oversized_body.length(), oversized_body]
    var server := _http_server(response)
    var config := _config()
    config.verify_endpoint = server.endpoint()
    var provider := _provider()
    assert_true(provider.configure(config).ok)

    var refreshed: Dictionary = await provider.refresh_online()

    assert_false(refreshed.ok)
    assert_eq(refreshed.error_type, "license")
    assert_eq(refreshed.error_code, "invalid_token")
    var retry: Dictionary = await provider.refresh_online()
    assert_false(retry.ok)
    assert_eq(retry.error_type, "request")
    assert_eq(retry.error_code, "not_activated")


func test_local_revocation_is_persisted_and_dominates_snapshot() -> void:
    var provider := _provider()
    assert_true(provider.configure(_config()).ok)
    assert_true(provider.revoke_local().ok)
    assert_eq(provider.get_snapshot().status, "revoked")
