class_name DiagnosticSupportBundle
extends RefCounted

const SCHEMA_VERSION := 1
const MAX_EVENTS := 200
const MAX_EVENT_AGE_SECONDS := 600.0
const MAX_RAW_SAMPLES := 150
const MAX_RAW_SAMPLE_AGE_SECONDS := 5.0
const MAX_JSON_BYTES := 256 * 1024
const SUPPORT_FILE := "support.json"

const ROOT_KEYS := [
    "schema_version", "build", "platform", "gpu", "controller", "license",
    "last_error_code", "events", "raw_samples",
]
const EVENT_KEYS := ["time_seconds", "code"]
const SAMPLE_KEYS := ["time_seconds", "roll", "pitch", "yaw", "throttle", "arm", "mode"]
const ROLE_NAMES := ["roll", "pitch", "yaw", "throttle"]
const LICENSE_STATES := [
    "not_activated", "online_valid", "offline_grace_valid", "offline_grace_expired",
    "invalid_token", "revoked",
]

var _events: Array[Dictionary] = []
var _raw_samples: Array[Dictionary] = []


func record_event(code: Variant, time_seconds: Variant) -> Dictionary:
    if not _is_code(code) or not _is_finite_number(time_seconds):
        return {"ok": false, "error": "event code/time is invalid"}
    _events.append({"code": String(code), "time_seconds": float(time_seconds)})
    return {"ok": true}


func record_raw_sample(time_seconds: Variant, sample: Variant) -> Dictionary:
    if not _is_finite_number(time_seconds):
        return {"ok": false, "error": "sample time is invalid"}
    var validation := _validate_sample_values(sample)
    if not validation.ok:
        return validation
    var recorded: Dictionary = sample.duplicate(true)
    recorded["time_seconds"] = float(time_seconds)
    _raw_samples.append(recorded)
    return {"ok": true}


func build_document(context: Variant, export_time_seconds: Variant) -> Dictionary:
    var context_error := _validate_context(context)
    if not context_error.is_empty() or not _is_finite_number(export_time_seconds):
        return {}
    var source: Dictionary = context
    var now := float(export_time_seconds)
    var document := {
        "schema_version": SCHEMA_VERSION,
        "build": source["build"].duplicate(true),
        "platform": source["platform"].duplicate(true),
        "gpu": source["gpu"].duplicate(true),
        "controller": _normalized_controller(source["controller"]),
        "license": {
            "state": source["license"]["status"],
            "remaining_seconds": source["license"]["offline_grace_remaining_seconds"],
        },
        "last_error_code": source["last_error_code"],
        "events": _recent_events(now),
        "raw_samples": _recent_samples(now),
    }
    return document


func audit_document(document: Variant) -> Dictionary:
    var shape_error := _validate_document(document)
    if not shape_error.is_empty():
        return {"ok": false, "error": shape_error}
    var canary_error := _find_canary(document)
    if not canary_error.is_empty():
        return {"ok": false, "error": canary_error}
    var json := JSON.stringify(document)
    if json.to_utf8_buffer().size() > MAX_JSON_BYTES:
        return {"ok": false, "error": "support.json exceeds 256 KiB"}
    return {"ok": true, "error": "", "json": json}


func export_bundle(destination_path: String, context: Variant, export_time_seconds: Variant) -> Dictionary:
    var temporary_path := "%s.tmp" % destination_path
    DirAccess.remove_absolute(temporary_path)
    var document := build_document(context, export_time_seconds)
    var audit := audit_document(document)
    if not audit.ok:
        return audit
    var payload: PackedByteArray = String(audit.json).to_utf8_buffer()
    var packer := ZIPPacker.new()
    if packer.open(temporary_path) != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "support bundle temporary ZIP could not be opened"}
    if packer.start_file(SUPPORT_FILE) != OK or packer.write_file(payload) != OK:
        packer.close()
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "support bundle ZIP write failed"}
    packer.close_file()
    if packer.close() != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "support bundle ZIP close failed"}

    var reader := ZIPReader.new()
    if reader.open(temporary_path) != OK:
        reader.close()
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "support bundle ZIP readback failed"}
    var files := reader.get_files()
    var readback: PackedByteArray = reader.read_file(SUPPORT_FILE) if files.has(SUPPORT_FILE) else PackedByteArray()
    var readback_document: Variant = JSON.parse_string(readback.get_string_from_utf8())
    var readback_audit := audit_document(readback_document)
    var archive_ok: bool = files.size() == 1 and files[0] == SUPPORT_FILE and readback == payload and readback_audit.ok
    reader.close()
    if not archive_ok:
        DirAccess.remove_absolute(temporary_path)
        if not readback_audit.ok:
            return {"ok": false, "error": "support bundle ZIP audit failed: %s" % readback_audit.error}
        return {"ok": false, "error": "support bundle ZIP audit failed"}
    if DirAccess.rename_absolute(temporary_path, destination_path) != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "support bundle atomic rename failed"}
    return {"ok": true, "path": destination_path, "document": document.duplicate(true)}


func _recent_events(now: float) -> Array:
    var recent: Array = []
    for event in _events:
        var relative := float(event.time_seconds) - now
        if relative >= -MAX_EVENT_AGE_SECONDS and relative <= 0.0:
            recent.append({"time_seconds": relative, "code": event.code})
    if recent.size() > MAX_EVENTS:
        recent = recent.slice(recent.size() - MAX_EVENTS)
    return recent


func _recent_samples(now: float) -> Array:
    var recent: Array = []
    for sample in _raw_samples:
        var relative := float(sample.time_seconds) - now
        if relative >= -MAX_RAW_SAMPLE_AGE_SECONDS and relative <= 0.0:
            recent.append({
                "time_seconds": relative,
                "roll": sample.roll,
                "pitch": sample.pitch,
                "yaw": sample.yaw,
                "throttle": sample.throttle,
                "arm": sample.arm,
                "mode": sample.mode,
            })
    if recent.size() > MAX_RAW_SAMPLES:
        recent = recent.slice(recent.size() - MAX_RAW_SAMPLES)
    return recent


func _validate_context(context: Variant) -> String:
    if typeof(context) != TYPE_DICTIONARY:
        return "bundle context must be an object"
    var source: Dictionary = context
    var error := _validate_exact_keys(source, ["build", "platform", "gpu", "controller", "license", "last_error_code"], "context")
    if not error.is_empty():
        return error
    error = _validate_document_section(source["build"], ["hash", "app_version"], "build")
    if not error.is_empty() or typeof(source["build"]["hash"]) != TYPE_STRING or typeof(source["build"]["app_version"]) != TYPE_STRING:
        return error if not error.is_empty() else "build fields must be strings"
    if String(source["build"]["hash"]).is_empty() or String(source["build"]["app_version"]).is_empty():
        return "build fields must not be empty"
    error = _validate_document_section(source["platform"], ["distribution", "version"], "platform")
    if not error.is_empty() or source["platform"]["distribution"] != "Ubuntu" or typeof(source["platform"]["version"]) != TYPE_STRING:
        return error if not error.is_empty() else "platform must describe Ubuntu"
    error = _validate_document_section(source["gpu"], ["vendor", "name", "api"], "gpu")
    if not error.is_empty():
        return error
    for key in ["vendor", "name", "api"]:
        if typeof(source["gpu"][key]) != TYPE_STRING:
            return "gpu fields must be strings"
        if String(source["gpu"][key]).is_empty():
            return "gpu fields must not be empty"
    error = _validate_controller(source["controller"])
    if not error.is_empty():
        return error
    error = _validate_license(source["license"])
    if not error.is_empty():
        return error
    if source["last_error_code"] != "" and not _is_code(source["last_error_code"]):
        return "last_error_code must be a named code"
    return ""


func _validate_controller(value: Variant) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "controller must be an object"
    var controller: Dictionary = value
    var error := _validate_exact_keys(controller, ["connected", "known", "confirmed", "usb_vendor_id", "usb_product_id", "mapping"], "controller")
    if not error.is_empty():
        return error
    for key in ["connected", "known", "confirmed"]:
        if typeof(controller[key]) != TYPE_BOOL:
            return "controller state must be boolean"
    for key in ["usb_vendor_id", "usb_product_id"]:
        if controller[key] != null and not _is_integral_number(controller[key]):
            return "USB identifiers must be integer or null"
    var mapping: Variant = controller["mapping"]
    if typeof(mapping) != TYPE_DICTIONARY:
        return "controller mapping must be an object"
    error = _validate_exact_keys(mapping, ["profile_schema_version", "axis_for_role", "reversed_for_role", "arm_button", "mode_button", "deadzone"], "gamepad mapping")
    if not error.is_empty() or not _is_integral_number(mapping["profile_schema_version"]) or int(mapping["profile_schema_version"]) != 1:
        return error if not error.is_empty() else "unsupported gamepad mapping schema"
    error = _validate_roles(mapping["axis_for_role"], ROLE_NAMES, TYPE_INT, "axis roles")
    if not error.is_empty():
        return error
    error = _validate_roles(mapping["reversed_for_role"], ROLE_NAMES, TYPE_BOOL, "reversed roles")
    if not error.is_empty():
        return error
    if not _is_integral_number(mapping["arm_button"]) or not _is_integral_number(mapping["mode_button"]):
        return "gamepad buttons must be integers"
    if not _is_finite_number(mapping["deadzone"]) or float(mapping["deadzone"]) < 0.0 or float(mapping["deadzone"]) > 1.0:
        return "deadzone must be a finite number from 0 to 1"
    return ""


func _normalized_controller(value: Dictionary) -> Dictionary:
    var result := value.duplicate(true)
    var mapping: Dictionary = value["mapping"]
    result["mapping"] = {
        "schema_version": int(mapping["profile_schema_version"]),
        "axis_roles": mapping["axis_for_role"].duplicate(true),
        "button_roles": {"arm": int(mapping["arm_button"]), "mode": int(mapping["mode_button"])},
        "reversed": mapping["reversed_for_role"].duplicate(true),
        "deadzone": float(mapping["deadzone"]),
    }
    return result


func _validate_output_controller(value: Variant) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "controller must be an object"
    var controller: Dictionary = value
    var error := _validate_exact_keys(controller, ["connected", "known", "confirmed", "usb_vendor_id", "usb_product_id", "mapping"], "controller")
    if not error.is_empty():
        return error
    for key in ["connected", "known", "confirmed"]:
        if typeof(controller[key]) != TYPE_BOOL:
            return "controller state must be boolean"
    for key in ["usb_vendor_id", "usb_product_id"]:
        if controller[key] != null and not _is_integral_number(controller[key]):
            return "USB identifiers must be integer or null"
    var mapping: Variant = controller["mapping"]
    if typeof(mapping) != TYPE_DICTIONARY:
        return "controller mapping must be an object"
    error = _validate_exact_keys(mapping, ["schema_version", "axis_roles", "button_roles", "reversed", "deadzone"], "mapping")
    if not error.is_empty() or not _is_integral_number(mapping["schema_version"]) or int(mapping["schema_version"]) != 1:
        return error if not error.is_empty() else "unsupported mapping schema"
    error = _validate_roles(mapping["axis_roles"], ROLE_NAMES, TYPE_INT, "axis roles")
    if not error.is_empty():
        return error
    error = _validate_roles(mapping["reversed"], ROLE_NAMES, TYPE_BOOL, "reversed roles")
    if not error.is_empty():
        return error
    error = _validate_roles(mapping["button_roles"], ["arm", "mode"], TYPE_INT, "button roles")
    if not error.is_empty():
        return error
    if not _is_finite_number(mapping["deadzone"]) or float(mapping["deadzone"]) < 0.0 or float(mapping["deadzone"]) > 1.0:
        return "deadzone must be a finite number from 0 to 1"
    return ""


func _validate_license(value: Variant) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "license must be an object"
    var license: Dictionary = value
    var error := _validate_exact_keys(license, ["status", "offline_grace_remaining_seconds"], "license snapshot")
    if not error.is_empty():
        return error
    if typeof(license["status"]) != TYPE_STRING or not LICENSE_STATES.has(license["status"]):
        return "license state is unsupported"
    if license["offline_grace_remaining_seconds"] != null and (not _is_integral_number(license["offline_grace_remaining_seconds"]) or int(license["offline_grace_remaining_seconds"]) < 0):
        return "license remaining_seconds must be a non-negative integer or null"
    return ""


func _validate_output_license(value: Variant) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "license must be an object"
    var license: Dictionary = value
    var error := _validate_exact_keys(license, ["state", "remaining_seconds"], "license")
    if not error.is_empty():
        return error
    if typeof(license["state"]) != TYPE_STRING or not LICENSE_STATES.has(license["state"]):
        return "license state is unsupported"
    if license["remaining_seconds"] != null and (not _is_integral_number(license["remaining_seconds"]) or int(license["remaining_seconds"]) < 0):
        return "license remaining_seconds must be a non-negative integer or null"
    return ""


func _validate_document(document: Variant) -> String:
    if typeof(document) != TYPE_DICTIONARY:
        return "support document must be an object"
    var source: Dictionary = document
    var error := _validate_exact_keys(source, ROOT_KEYS, "support document")
    if not error.is_empty():
        return error
    if not _is_integral_number(source["schema_version"]) or int(source["schema_version"]) != SCHEMA_VERSION:
        return "unsupported support schema"
    error = _validate_document_section(source["build"], ["hash", "app_version"], "build")
    if not error.is_empty():
        return error
    for key in ["hash", "app_version"]:
        if typeof(source["build"][key]) != TYPE_STRING or String(source["build"][key]).is_empty():
            return "build fields must be non-empty strings"
    error = _validate_document_section(source["platform"], ["distribution", "version"], "platform")
    if not error.is_empty() or source["platform"]["distribution"] != "Ubuntu" or typeof(source["platform"]["version"]) != TYPE_STRING or String(source["platform"]["version"]).is_empty():
        return error if not error.is_empty() else "platform must describe Ubuntu"
    error = _validate_document_section(source["gpu"], ["vendor", "name", "api"], "gpu")
    if not error.is_empty():
        return error
    for key in ["vendor", "name", "api"]:
        if typeof(source["gpu"][key]) != TYPE_STRING or String(source["gpu"][key]).is_empty():
            return "gpu fields must be non-empty strings"
    error = _validate_output_controller(source["controller"])
    if not error.is_empty():
        return error
    error = _validate_output_license(source["license"])
    if not error.is_empty():
        return error
    if source["last_error_code"] != "" and not _is_code(source["last_error_code"]):
        return "last_error_code must be a named code"
    if typeof(source["events"]) != TYPE_ARRAY or source["events"].size() > MAX_EVENTS:
        return "events must be an array of at most 200 entries"
    for event in source["events"]:
        if typeof(event) != TYPE_DICTIONARY:
            return "event must be an object"
        error = _validate_exact_keys(event, EVENT_KEYS, "event")
        if not error.is_empty() or not _is_finite_number(event.get("time_seconds")) or not _is_code(event.get("code")):
            return error if not error.is_empty() else "event fields are invalid"
    if typeof(source["raw_samples"]) != TYPE_ARRAY or source["raw_samples"].size() > MAX_RAW_SAMPLES:
        return "raw_samples must be an array of at most 150 entries"
    for sample in source["raw_samples"]:
        if typeof(sample) != TYPE_DICTIONARY:
            return "raw sample must be an object"
        error = _validate_exact_keys(sample, SAMPLE_KEYS, "raw sample")
        if not error.is_empty():
            return error
        if not _is_finite_number(sample["time_seconds"]):
            return "raw sample time is invalid"
        var sample_validation := _validate_sample_values(sample)
        if not sample_validation.ok:
            return sample_validation.error
    return ""


func _validate_sample_values(sample: Variant) -> Dictionary:
    if typeof(sample) != TYPE_DICTIONARY:
        return {"ok": false, "error": "raw sample must be an object"}
    for axis in ["roll", "pitch", "yaw", "throttle"]:
        if not _is_finite_number(sample.get(axis)):
            return {"ok": false, "error": "raw sample axes must be finite numbers"}
    for button in ["arm", "mode"]:
        if typeof(sample.get(button)) != TYPE_BOOL:
            return {"ok": false, "error": "raw sample buttons must be boolean"}
    return {"ok": true}


func _validate_roles(value: Variant, names: Array, expected_type: int, label: String) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "%s must be an object" % label
    var roles: Dictionary = value
    var error := _validate_exact_keys(roles, names, label)
    if not error.is_empty():
        return error
    for name in names:
        if expected_type == TYPE_INT and not _is_integral_number(roles[name]):
            return "%s must contain the expected types" % label
        if expected_type != TYPE_INT and typeof(roles[name]) != expected_type:
            return "%s must contain the expected types" % label
    return ""


func _validate_document_section(value: Variant, keys: Array, label: String) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "%s must be an object" % label
    return _validate_exact_keys(value, keys, label)


func _validate_exact_keys(value: Variant, allowed: Array, label: String) -> String:
    if typeof(value) != TYPE_DICTIONARY:
        return "%s must be an object" % label
    var dictionary: Dictionary = value
    for key in dictionary.keys():
        if not allowed.has(key):
            return "unknown %s key: %s" % [label, key]
    for key in allowed:
        if not dictionary.has(key):
            return "missing %s key: %s" % [label, key]
    return ""


func _find_canary(value: Variant) -> String:
    match typeof(value):
        TYPE_DICTIONARY:
            for key in value.keys():
                var key_error := _find_canary(String(key))
                if not key_error.is_empty():
                    return key_error
                var value_error := _find_canary(value[key])
                if not value_error.is_empty():
                    return value_error
        TYPE_ARRAY:
            for item in value:
                var item_error := _find_canary(item)
                if not item_error.is_empty():
                    return item_error
        TYPE_STRING:
            var candidate := String(value).to_lower()
            for marker in ["eyj", "/home/", "home=", "hostname=", "username=", "command line", "license_key", "customer_id", "device_id", "claims", "serial", "guid", "raw_name", "free_text", "screenshot", "crash dump", "telemetry.csv"]:
                if candidate.contains(marker):
                    return "forbidden secret or PII canary"
            if _looks_like_ipv4(candidate) or _looks_like_mac(candidate):
                return "forbidden network identity canary"
    return ""


func _looks_like_ipv4(value: String) -> bool:
    var parts := value.split(".")
    if parts.size() != 4:
        return false
    for part in parts:
        if not part.is_valid_int() or int(part) < 0 or int(part) > 255:
            return false
    return true


func _looks_like_mac(value: String) -> bool:
    var parts := value.split(":")
    if parts.size() != 6:
        return false
    for part in parts:
        if part.length() != 2 or part.to_int() < 0:
            return false
    return true


func _is_code(value: Variant) -> bool:
    if typeof(value) != TYPE_STRING:
        return false
    var code := String(value)
    if code.is_empty():
        return false
    var regex := RegEx.new()
    regex.compile("^[a-z][a-z0-9_]{0,63}$")
    return regex.search(code) != null


func _is_finite_number(value: Variant) -> bool:
    return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value))


func _is_integral_number(value: Variant) -> bool:
    return _is_finite_number(value) and is_equal_approx(float(value), float(int(value)))
