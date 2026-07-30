class_name Px4QualificationTraceWriter
extends RefCounted

## Writes diagnostic-only PX4 qualification evidence without ever exposing a
## partially serialized trace at the published path.


static func replace_json(path: String, document: Dictionary) -> Dictionary:
    if path.is_empty():
        return {"ok": false, "error": "trace path is empty"}
    var temporary_path := "%s.tmp" % path
    if FileAccess.file_exists(temporary_path):
        DirAccess.remove_absolute(temporary_path)
    var output := FileAccess.open(temporary_path, FileAccess.WRITE)
    if output == null:
        return {"ok": false, "error": "trace temporary file could not be opened"}
    output.store_string(JSON.stringify(document))
    output.flush()
    var write_error := output.get_error()
    output.close()
    if write_error != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "trace temporary file write failed"}
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(temporary_path))
    if typeof(parsed) != TYPE_DICTIONARY:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "trace temporary file is not parseable JSON"}
    if DirAccess.rename_absolute(temporary_path, path) != OK:
        DirAccess.remove_absolute(temporary_path)
        return {"ok": false, "error": "trace atomic rename failed"}
    return {"ok": true, "error": ""}
