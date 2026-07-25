extends RefCounted

const DESCRIPTOR_PATHS := {
    "industrial_yard": "res://config/maps/industrial_yard.json",
    "terrain3d_range": "res://config/maps/terrain3d_range.json"
}
const REQUIRED_FIELDS := [
    "id",
    "name",
    "type",
    "recommended_aircraft",
    "wind_preset",
    "spawn_count",
    "spawns",
    "mode"
]

var last_ok := true
var last_error := ""

func load_descriptor(map_id: String) -> Dictionary:
    if not DESCRIPTOR_PATHS.has(map_id):
        return _fail("unknown free flight map id: %s" % map_id)
    var parsed := _read_json(DESCRIPTOR_PATHS[map_id])
    if not parsed.ok:
        return _fail(parsed.error)
    var descriptor: Dictionary = parsed.value
    var validation_error := validate_descriptor(descriptor)
    if validation_error != "":
        return _fail("%s: %s" % [DESCRIPTOR_PATHS[map_id], validation_error])
    if descriptor.id != map_id:
        return _fail("descriptor id %s does not match requested map id %s" % [descriptor.id, map_id])
    last_ok = true
    last_error = ""
    return descriptor

func validate_descriptor(descriptor: Dictionary) -> String:
    for field in REQUIRED_FIELDS:
        if not descriptor.has(field):
            return "missing required field %s" % field
    for field in ["id", "name", "type", "recommended_aircraft", "wind_preset", "mode"]:
        if not (descriptor[field] is String) or str(descriptor[field]).strip_edges().is_empty():
            return "%s must be a non-empty string" % field
    if not ["calm", "light", "moderate", "severe"].has(str(descriptor.wind_preset)):
        return "wind_preset must be one of calm, light, moderate, severe"
    if not (descriptor.spawn_count is int or descriptor.spawn_count is float):
        return "spawn_count must be a positive integer"
    var spawn_count := float(descriptor.spawn_count)
    if spawn_count < 1.0 or not is_equal_approx(spawn_count, roundf(spawn_count)):
        return "spawn_count must be a positive integer"
    if not (descriptor.spawns is Array) or descriptor.spawns.is_empty():
        return "spawns must be a non-empty array"
    if descriptor.spawns.size() != int(spawn_count):
        return "spawn_count must match spawns"
    var spawn_names: Array[String] = []
    for spawn in descriptor.spawns:
        if not (spawn is Dictionary) or not spawn.has("name") or not (spawn.name is String) or str(spawn.name).strip_edges().is_empty():
            return "each spawn must define a non-empty name"
        if spawn_names.has(String(spawn.name)):
            return "spawn names must be unique"
        spawn_names.append(String(spawn.name))
    return ""

func _read_json(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"ok": false, "error": "cannot open map descriptor: %s" % path}
    var json := JSON.new()
    if json.parse(file.get_as_text()) != OK:
        return {"ok": false, "error": "bad map descriptor JSON in %s at line %d: %s" % [path, json.get_error_line(), json.get_error_message()]}
    if not (json.data is Dictionary):
        return {"ok": false, "error": "map descriptor root must be an object: %s" % path}
    return {"ok": true, "value": json.data}

func _fail(error: String) -> Dictionary:
    last_ok = false
    last_error = error
    push_warning(error)
    return {}
