extends RefCounted
class_name GspPresetStore

const PRESET_DIRECTORY := "user://gsp/presets"
const NAME_MIN_LENGTH := 1
const NAME_MAX_LENGTH := 64
const NOTE_MAX_LENGTH := 512
const MAX_FILE_BYTES := 64 * 1024
const SCHEMA_VERSION := 1
const REQUIRED_FIELDS := ["schema_version", "name", "created_at", "registry_hash", "sim_version", "values"]
const OPTIONAL_FIELDS := ["note"]


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
            var has_before := left.has(key) and is_finite(float(left[key]))
            var has_after := right.has(key) and is_finite(float(right[key]))
            changes.append({
                "parameter": key,
                "before": float(left[key]) if has_before else null,
                "after": float(right[key]) if has_after else null,
                "absolute": null,
                "absolute_status": "missing_value",
                "percentage": null,
                "percentage_status": "missing_value",
            })
            continue
        var before := float(left[key])
        var after := float(right[key])
        if not is_finite(before) or not is_finite(after) or before == after:
            continue
        var delta := after - before
        var change := {"parameter": key, "before": before, "after": after}
        if not is_finite(delta):
            change["absolute"] = null
            change["absolute_status"] = "unrepresentable"
            change["percentage"] = null
            change["percentage_status"] = "unrepresentable"
        elif before == 0.0:
            change["absolute"] = delta
            change["percentage"] = null
            change["percentage_status"] = "zero_baseline"
        elif (before < 0.0 and after > 0.0) or (before > 0.0 and after < 0.0):
            change["absolute"] = delta
            change["percentage"] = null
            change["percentage_status"] = "sign_change"
        else:
            change["absolute"] = delta
            var percentage := delta / absf(before) * 100.0
            if is_finite(percentage):
                change["percentage"] = percentage
                change["percentage_status"] = "finite"
            else:
                change["percentage"] = null
                change["percentage_status"] = "unrepresentable"
        changes.append(change)
    return changes


static func classify_migration(values: Variant, registry: Array) -> Dictionary:
    if typeof(values) != TYPE_DICTIONARY or values.is_empty():
        return {"ok": false, "error": "preset values must be a non-empty object"}
    var current_keys: Dictionary = {}
    var final_values: Dictionary = {}
    var requested_values: Dictionary = {}
    var missing: Array = []
    var out_of_range: Array = []
    for descriptor_value in registry:
        if typeof(descriptor_value) != TYPE_DICTIONARY:
            return {"ok": false, "error": "tuning registry is malformed"}
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        if key.is_empty() or current_keys.has(key):
            return {"ok": false, "error": "tuning registry contains duplicate or empty keys"}
        current_keys[key] = true
        var minimum := float(descriptor.get("min", -INF))
        var maximum := float(descriptor.get("max", INF))
        if values.has(key):
            var original := float(values[key])
            requested_values[key] = original
            var corrected := clampf(original, minimum, maximum)
            final_values[key] = corrected
            if original != corrected:
                out_of_range.append({
                    "classification": "out_of_range",
                    "parameter": key,
                    "original_value": original,
                    "corrected_value": corrected,
                    "min": minimum,
                    "max": maximum,
                })
        else:
            var default_value := clampf(float(descriptor.get("default", 0.0)), minimum, maximum)
            final_values[key] = default_value
            requested_values[key] = default_value
            missing.append({
                "classification": "missing",
                "parameter": key,
                "default_value": default_value,
                "corrected_value": default_value,
            })
    var removed: Array = []
    for key_value in values.keys():
        var key := String(key_value)
        if not current_keys.has(key):
            removed.append({
                "classification": "removed",
                "parameter": key,
                "value": float(values[key]),
            })
    removed.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.parameter) < String(right.parameter))
    return {
        "ok": true,
        "removed": removed,
        "missing": missing,
        "out_of_range": out_of_range,
        "values": final_values,
        "requested_values": requested_values,
    }


func save_preset(name: String, values: Dictionary, registry_hash: String, sim_version: String, note: String = "") -> Dictionary:
    var name_result := validate_name(name)
    if not bool(name_result.get("ok", false)):
        return name_result
    var values_result := _validate_values(values)
    if not bool(values_result.get("ok", false)):
        return values_result
    if registry_hash.is_empty() or sim_version.is_empty():
        return {"ok": false, "error": "preset metadata is invalid"}
    if note.to_utf8_buffer().size() > NOTE_MAX_LENGTH:
        return {"ok": false, "error": "preset note is too long"}
    var preset := {
        "schema_version": SCHEMA_VERSION,
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
    if file.get_length() > MAX_FILE_BYTES:
        file.close()
        return {"ok": false, "error": "preset file is too large"}
    var content := file.get_buffer(file.get_length())
    var content_hash := _hash_content(content)
    var parser := JSON.new()
    var parse_error := parser.parse(content.get_string_from_utf8())
    file.close()
    if parse_error != OK:
        return {"ok": false, "error": "preset JSON is malformed"}
    var result := _validate_preset(parser.data, expected_name)
    if not bool(result.get("ok", false)):
        return result
    return {"ok": true, "preset": result.preset, "content_hash": content_hash}


static func _hash_content(content: PackedByteArray) -> String:
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    context.update(content)
    return context.finish().hex_encode()


static func _validate_preset(candidate: Variant, expected_name: String = "") -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "preset document must be an object"}
    var preset: Dictionary = candidate.duplicate(true)
    for field in preset.keys():
        if typeof(field) != TYPE_STRING or (field not in REQUIRED_FIELDS and field not in OPTIONAL_FIELDS):
            return {"ok": false, "error": "preset contains an unknown field"}
    for field in REQUIRED_FIELDS:
        if not preset.has(field):
            return {"ok": false, "error": "preset missing field: %s" % field}
    if (typeof(preset.schema_version) != TYPE_INT and typeof(preset.schema_version) != TYPE_FLOAT) or float(preset.schema_version) != float(SCHEMA_VERSION):
        return {"ok": false, "error": "unsupported preset schema version"}
    var name_result := validate_name(preset.name)
    if not bool(name_result.get("ok", false)):
        return name_result
    if not expected_name.is_empty() and String(preset.name) != expected_name:
        return {"ok": false, "error": "preset name does not match path"}
    for field in ["created_at", "registry_hash", "sim_version"]:
        if typeof(preset[field]) != TYPE_STRING or String(preset[field]).is_empty():
            return {"ok": false, "error": "preset %s must be a non-empty string" % field}
    if preset.has("note") and (typeof(preset.note) != TYPE_STRING or String(preset.note).to_utf8_buffer().size() > NOTE_MAX_LENGTH):
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
