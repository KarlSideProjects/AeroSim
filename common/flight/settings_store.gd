class_name SettingsStore
extends RefCounted

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")

const SCHEMA_VERSION := 1
const FIELD_NAMES := [
    "schema_version",
    "confirmed_gamepad",
    "rates",
    "osd",
    "camera",
    "language",
    "quality",
]
const DEFAULT_PATH := "user://settings.json"

var path: String


func _init(settings_path: String = DEFAULT_PATH) -> void:
    path = settings_path


func default_document() -> Dictionary:
    return {
        "schema_version": SCHEMA_VERSION,
        "confirmed_gamepad": null,
        "rates": null,
        "osd": null,
        "camera": null,
        "language": null,
        "quality": null,
    }


func validate_document(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "settings document must be an object"}
    var source: Dictionary = candidate
    for key in source.keys():
        if not FIELD_NAMES.has(key):
            return {"ok": false, "error": "unknown settings field: %s" % key}
    for key in FIELD_NAMES:
        if not source.has(key):
            return {"ok": false, "error": "missing settings field: %s" % key}
    if typeof(source["schema_version"]) != TYPE_INT or int(source["schema_version"]) != SCHEMA_VERSION:
        return {"ok": false, "error": "unsupported settings schema_version"}
    for key in FIELD_NAMES.slice(1):
        if source[key] != null and typeof(source[key]) != TYPE_DICTIONARY:
            return {"ok": false, "error": "%s must be null or an object" % key}
    if source["confirmed_gamepad"] != null:
        var profile_result := InputProfiles.GamepadProfile.validate_persisted_dict(source["confirmed_gamepad"])
        if not profile_result.ok:
            return profile_result
    if source["rates"] != null:
        var rates_result := RatesProfile.validate_profile(source["rates"])
        if not rates_result.ok:
            return rates_result
    var normalized := source.duplicate(true)
    normalized["schema_version"] = SCHEMA_VERSION
    return {"ok": true, "error": "", "document": normalized}


func load_document() -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"ok": true, "error": "", "document": default_document(), "recovered": false}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return _recovery_result("settings file could not be opened")
    if OS.has_feature("linux") and FileAccess.get_unix_permissions(path) != 384:
        file.close()
        return _recovery_result("settings file permissions must be 0600")
    var parser := JSON.new()
    var parse_error := parser.parse(file.get_as_text())
    file.close()
    if parse_error != OK:
        return _recovery_result("settings JSON is malformed")
    var parsed = _normalize_loaded_document(parser.data)
    var result := validate_document(parsed)
    if not result.ok:
        return _recovery_result(result.error)
    result["recovered"] = false
    return result


func save_document(candidate: Variant) -> Dictionary:
    var result := validate_document(candidate)
    if not result.ok:
        return result
    var temporary_path := "%s.tmp" % path
    var file := FileAccess.open(temporary_path, FileAccess.WRITE)
    if file == null:
        return {"ok": false, "error": "settings temporary file could not be opened"}
    file.store_string(JSON.stringify(result.document))
    var write_error: Error = file.get_error()
    file.close()
    if write_error != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "settings temporary file write failed"}
    if OS.has_feature("linux"):
        var permission_error: Error = FileAccess.set_unix_permissions(temporary_path, 384)
        if permission_error != OK or FileAccess.get_unix_permissions(temporary_path) != 384:
            DirAccess.remove_absolute(temporary_path)
            return {"ok": false, "error": "settings temporary file permissions could not be set to 0600"}
    var readback := load_document_from_path(temporary_path)
    if not readback.ok:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "settings readback validation failed: %s" % readback.error}
    if DirAccess.rename_absolute(temporary_path, path) != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "settings atomic rename failed"}
    return {"ok": true, "error": "", "document": result.document.duplicate(true)}


func factory_reset() -> Dictionary:
    return save_document(default_document())


func load_document_from_path(candidate_path: String) -> Dictionary:
    if not FileAccess.file_exists(candidate_path):
        return {"ok": false, "error": "settings temporary file disappeared", "document": {}}
    var file := FileAccess.open(candidate_path, FileAccess.READ)
    if file == null:
        return {"ok": false, "error": "settings temporary file could not be read", "document": {}}
    var parser := JSON.new()
    var parse_error := parser.parse(file.get_as_text())
    file.close()
    if parse_error != OK:
        return {"ok": false, "error": "settings temporary JSON is malformed", "document": {}}
    var result := validate_document(_normalize_loaded_document(parser.data))
    if not result.ok:
        return result
    return result


func _normalize_loaded_document(candidate: Variant) -> Variant:
    if typeof(candidate) != TYPE_DICTIONARY:
        return candidate
    var normalized: Dictionary = candidate.duplicate(true)
    if typeof(normalized.get("schema_version")) in [TYPE_INT, TYPE_FLOAT]:
        normalized["schema_version"] = _normalize_integer_json_value(normalized["schema_version"])
    var profile = normalized.get("confirmed_gamepad")
    if typeof(profile) == TYPE_DICTIONARY:
        var normalized_profile: Dictionary = profile.duplicate(true)
        for key in ["profile_schema_version", "arm_button", "mode_button"]:
            if typeof(normalized_profile.get(key)) in [TYPE_INT, TYPE_FLOAT]:
                normalized_profile[key] = _normalize_integer_json_value(normalized_profile[key])
        var axes = normalized_profile.get("axis_for_role")
        if typeof(axes) == TYPE_DICTIONARY:
            var normalized_axes: Dictionary = axes.duplicate(true)
            for role in normalized_axes:
                if typeof(normalized_axes[role]) in [TYPE_INT, TYPE_FLOAT]:
                    normalized_axes[role] = _normalize_integer_json_value(normalized_axes[role])
            normalized_profile["axis_for_role"] = normalized_axes
        normalized["confirmed_gamepad"] = normalized_profile
    return normalized


func _normalize_integer_json_value(value: Variant) -> Variant:
    if typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), float(int(value))):
        return int(value)
    return value


func _recovery_result(reason: String) -> Dictionary:
    return {
        "ok": false,
        "error": reason,
        "document": default_document(),
        "recovered": true,
    }
