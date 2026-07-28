class_name SettingsStore
extends RefCounted

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")
const QualityProfile = preload("res://common/flight/quality_profile.gd")
const LanguageProfile = preload("res://common/flight/language_profile.gd")
const CameraProfile = preload("res://common/flight/camera_profile.gd")
const OsdProfile = preload("res://common/flight/osd_profile.gd")
const QuickAdjustProfile = InputProfiles.QuickAdjustProfile

const SCHEMA_VERSION := 1
const FIELD_NAMES := [
    "schema_version",
    "confirmed_gamepad",
    "rates",
    "osd",
    "camera",
    "language",
    "quality",
    "quick_adjust",
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
        "quick_adjust": null,
    }


func validate_document(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "settings document must be an object"}
    var source: Dictionary = candidate.duplicate(true)
    if not source.has("quick_adjust"):
        source["quick_adjust"] = null
    for key in source.keys():
        if not FIELD_NAMES.has(key):
            return {"ok": false, "error": "unknown settings field: %s" % key}
    for key in FIELD_NAMES:
        if not source.has(key) and key != "quick_adjust":
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
    var camera_result: Dictionary = {"ok": true, "profile": null}
    var osd_result: Dictionary = {"ok": true, "profile": null}
    if source["camera"] != null:
        camera_result = CameraProfile.validate_profile(source["camera"])
        if not camera_result.ok:
            return camera_result
    if source["osd"] != null:
        osd_result = OsdProfile.validate_profile(source["osd"])
        if not osd_result.ok:
            return osd_result
    var language_result: Dictionary = {}
    if source["language"] != null:
        language_result = LanguageProfile.validate_profile(source["language"])
        if not language_result.ok:
            return language_result
    var quality_result: Dictionary = {}
    if source["quality"] != null:
        quality_result = QualityProfile.validate_profile(source["quality"])
        if not quality_result.ok:
            return quality_result
    var quick_adjust_result: Dictionary = {"ok": true, "profile": null}
    if source.get("quick_adjust") != null:
        quick_adjust_result = QuickAdjustProfile.validate_profile(source["quick_adjust"])
        if not quick_adjust_result.ok:
            return quick_adjust_result
    var normalized := source.duplicate(true)
    normalized["schema_version"] = SCHEMA_VERSION
    if source["camera"] != null:
        normalized["camera"] = camera_result.profile
    if source["osd"] != null:
        normalized["osd"] = osd_result.profile
    if source["quality"] != null:
        normalized["quality"] = quality_result.profile
    if source["language"] != null:
        normalized["language"] = language_result.profile if source["language"].has("schema_version") else source["language"].duplicate(true)
    if source.get("quick_adjust") != null:
        normalized["quick_adjust"] = quick_adjust_result.profile
    elif not normalized.has("quick_adjust"):
        normalized["quick_adjust"] = null
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
    var language = normalized.get("language")
    if typeof(language) == TYPE_DICTIONARY:
        var normalized_language: Dictionary = language.duplicate(true)
        if typeof(normalized_language.get("schema_version")) in [TYPE_INT, TYPE_FLOAT]:
            normalized_language["schema_version"] = _normalize_integer_json_value(normalized_language["schema_version"])
        normalized["language"] = normalized_language
    for slot in ["camera", "osd"]:
        var slot_profile = normalized.get(slot)
        if typeof(slot_profile) == TYPE_DICTIONARY:
            var normalized_slot_profile: Dictionary = slot_profile.duplicate(true)
            if typeof(normalized_slot_profile.get("schema_version")) in [TYPE_INT, TYPE_FLOAT]:
                normalized_slot_profile["schema_version"] = _normalize_integer_json_value(normalized_slot_profile["schema_version"])
            var positions = normalized_slot_profile.get("positions")
            if slot == "osd" and normalized_slot_profile.get("schema_version") == OsdProfile.SCHEMA_VERSION and typeof(positions) == TYPE_DICTIONARY \
                    and positions.get("warnings") == {"x": 0.03, "y": 0.78} \
                    and positions.get("reset_hint") == {"x": 0.03, "y": 0.90}:
                normalized_slot_profile["positions"]["warnings"] = OsdProfile.DEFAULT_POSITIONS["warnings"].duplicate(true)
                normalized_slot_profile["positions"]["reset_hint"] = OsdProfile.DEFAULT_POSITIONS["reset_hint"].duplicate(true)
            normalized[slot] = normalized_slot_profile
    var quick_adjust = normalized.get("quick_adjust")
    if typeof(quick_adjust) == TYPE_DICTIONARY:
        var normalized_quick_adjust: Dictionary = quick_adjust.duplicate(true)
        if typeof(normalized_quick_adjust.get("schema_version")) in [TYPE_INT, TYPE_FLOAT]:
            normalized_quick_adjust["schema_version"] = _normalize_integer_json_value(normalized_quick_adjust["schema_version"])
        if typeof(normalized_quick_adjust.get("slots")) == TYPE_ARRAY:
            var normalized_slots: Array = []
            for slot_value in normalized_quick_adjust.slots:
                if typeof(slot_value) != TYPE_DICTIONARY:
                    normalized_slots.append(slot_value)
                    continue
                var normalized_slot: Dictionary = slot_value.duplicate(true)
                for key in ["device", "axis", "negative_key", "positive_key"]:
                    if typeof(normalized_slot.get(key)) in [TYPE_INT, TYPE_FLOAT]:
                        normalized_slot[key] = _normalize_integer_json_value(normalized_slot[key])
                normalized_slots.append(normalized_slot)
            normalized_quick_adjust["slots"] = normalized_slots
        normalized["quick_adjust"] = normalized_quick_adjust
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
