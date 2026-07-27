extends RefCounted
class_name GspPresetStore

const PRESET_DIRECTORY := "user://gsp/presets"
const NAME_MIN_LENGTH := 1
const NAME_MAX_LENGTH := 64
const NOTE_MAX_LENGTH := 512
const REQUIRED_FIELDS := ["name", "created_at", "registry_hash", "sim_version", "values"]


static func validate_name(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_STRING:
        return {"ok": false, "error": "preset name must be a string"}
    var name := String(candidate)
    if name.length() < NAME_MIN_LENGTH or name.length() > NAME_MAX_LENGTH:
        return {"ok": false, "error": "preset name length must be between 1 and 64"}
    if name.to_utf8_buffer().size() != name.length():
        return {"ok": false, "error": "preset name must contain ASCII characters only"}
    for index in name.length():
        var codepoint := name.unicode_at(index)
        var alphanumeric := codepoint >= 48 and codepoint <= 57 or codepoint >= 65 and codepoint <= 90 or codepoint >= 97 and codepoint <= 122
        if not alphanumeric and codepoint != 45 and codepoint != 95:
            return {"ok": false, "error": "preset name may contain only ASCII letters, digits, hyphens, and underscores"}
    var first := name.unicode_at(0)
    if not (first >= 48 and first <= 57 or first >= 65 and first <= 90 or first >= 97 and first <= 122):
        return {"ok": false, "error": "preset name must start with an ASCII letter or digit"}
    return {"ok": true, "name": name}


static func preset_path(name: String) -> String:
    var validation := validate_name(name)
    if not bool(validation.get("ok", false)):
        return ""
    return PRESET_DIRECTORY.path_join("%s.json" % String(validation.name))


static func diff_values(left: Dictionary, right: Dictionary) -> Array:
    var keys: Array[String] = []
    for key in left.keys() + right.keys():
        var name := String(key)
        if name not in keys:
            keys.append(name)
    keys.sort()
    var changes: Array = []
    for key in keys:
        if not left.has(key) or not right.has(key):
            continue
        var before := float(left[key])
        var after := float(right[key])
        if not is_finite(before) or not is_finite(after) or is_equal_approx(before, after):
            continue
        var change := {"parameter": key, "before": before, "after": after, "absolute": after - before}
        if is_zero_approx(before):
            change["percentage"] = null
            change["percentage_status"] = "zero_baseline"
        elif before * after < 0.0:
            change["percentage"] = null
            change["percentage_status"] = "sign_change"
        else:
            change["percentage"] = (after - before) / absf(before) * 100.0
            change["percentage_status"] = "finite"
        changes.append(change)
    return changes


func save_preset(name: String, values: Dictionary, registry_hash: String, sim_version: String, note: String = "") -> Dictionary:
    var name_result := validate_name(name)
    if not bool(name_result.get("ok", false)):
        return name_result
    var values_result := _validate_values(values)
    if not bool(values_result.get("ok", false)):
        return values_result
    if note.length() > NOTE_MAX_LENGTH:
        return {"ok": false, "error": "preset note is too long"}
    var preset := {
        "name": name,
        "created_at": Time.get_datetime_string_from_system(true),
        "registry_hash": registry_hash,
        "sim_version": sim_version,
        "values": values.duplicate(true),
    }
    if not note.is_empty():
        preset["note"] = note
    var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PRESET_DIRECTORY))
    if directory_error != OK:
        return {"ok": false, "error": "preset directory could not be created"}
    var path := preset_path(name)
    var temporary_path := "%s.tmp-%d" % [path, Time.get_ticks_usec()]
    var file := FileAccess.open(temporary_path, FileAccess.WRITE)
    if file == null:
        return {"ok": false, "error": "preset temporary file could not be opened"}
    file.store_string(JSON.stringify(preset))
    var write_error: Error = file.get_error()
    file.flush()
    file.close()
    if write_error != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "preset temporary file write failed"}
    if OS.has_feature("linux"):
        FileAccess.set_unix_permissions(temporary_path, 384)
    var readback := _read_preset_file(temporary_path)
    if not bool(readback.get("ok", false)):
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "preset readback validation failed: %s" % String(readback.get("error", "invalid preset"))}
    if DirAccess.rename_absolute(temporary_path, path) != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "preset atomic rename failed"}
    return {"ok": true, "preset": preset.duplicate(true)}


func retrieve_preset(name: String) -> Dictionary:
    var name_result := validate_name(name)
    if not bool(name_result.get("ok", false)):
        return name_result
    var path := preset_path(name)
    if not FileAccess.file_exists(path):
        return {"ok": false, "error": "preset not found"}
    return _read_preset_file(path, name)


func list_presets() -> Dictionary:
    var presets: Array = []
    var directory := DirAccess.open(PRESET_DIRECTORY)
    if directory == null:
        return {"ok": true, "presets": presets}
    directory.list_dir_begin()
    var file_name := directory.get_next()
    while not file_name.is_empty():
        if not directory.current_is_dir() and file_name.ends_with(".json"):
            var name := file_name.trim_suffix(".json")
            var name_result := validate_name(name)
            if bool(name_result.get("ok", false)):
                var loaded := retrieve_preset(name)
                if bool(loaded.get("ok", false)):
                    var preset: Dictionary = loaded.preset
                    var summary := preset.duplicate(true)
                    summary.erase("values")
                    presets.append(summary)
        file_name = directory.get_next()
    directory.list_dir_end()
    presets.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.name) < String(right.name))
    return {"ok": true, "presets": presets}


func _read_preset_file(path: String, expected_name: String = "") -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"ok": false, "error": "preset could not be opened"}
    var parser := JSON.new()
    var parse_error := parser.parse(file.get_as_text())
    file.close()
    if parse_error != OK:
        return {"ok": false, "error": "preset JSON is malformed"}
    var result := _validate_preset(parser.data, expected_name)
    if not bool(result.get("ok", false)):
        return result
    return {"ok": true, "preset": result.preset}


static func _validate_preset(candidate: Variant, expected_name: String = "") -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "preset document must be an object"}
    var preset: Dictionary = candidate.duplicate(true)
    for field in REQUIRED_FIELDS:
        if not preset.has(field):
            return {"ok": false, "error": "preset missing field: %s" % field}
    var name_result := validate_name(preset.name)
    if not bool(name_result.get("ok", false)):
        return name_result
    if not expected_name.is_empty() and String(preset.name) != expected_name:
        return {"ok": false, "error": "preset name does not match path"}
    for field in ["created_at", "registry_hash", "sim_version"]:
        if typeof(preset[field]) != TYPE_STRING or String(preset[field]).is_empty():
            return {"ok": false, "error": "preset %s must be a non-empty string" % field}
    if preset.has("note") and (typeof(preset.note) != TYPE_STRING or String(preset.note).length() > NOTE_MAX_LENGTH):
        return {"ok": false, "error": "preset note is invalid"}
    var values_result := _validate_values(preset.values)
    if not bool(values_result.get("ok", false)):
        return values_result
    return {"ok": true, "preset": preset}


static func _validate_values(values: Variant) -> Dictionary:
    if typeof(values) != TYPE_DICTIONARY or values.is_empty():
        return {"ok": false, "error": "preset values must be a non-empty object"}
    for key in values.keys():
        if typeof(key) != TYPE_STRING or String(key).is_empty():
            return {"ok": false, "error": "preset value keys must be strings"}
        if typeof(values[key]) != TYPE_INT and typeof(values[key]) != TYPE_FLOAT or not is_finite(float(values[key])):
            return {"ok": false, "error": "preset values must be finite numbers"}
    return {"ok": true}
