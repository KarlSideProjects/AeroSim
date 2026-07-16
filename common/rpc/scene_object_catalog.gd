class_name SceneObjectCatalog
extends Node3D

const CATALOG_KEYS := {"version": true, "objects": true}
const OBJECT_KEYS := {
    "id": true,
    "resource": true,
    "provenance": true,
    "license": true,
    "segmentation_id": true,
    "size": true,
    "bounds": true,
    "collision": true,
    "mobility": true,
    "destroyable": true,
}
const ALLOWED_RESOURCES := ["primitive_box"]
const ALLOWED_MOBILITY := ["movable"]

var _definitions: Dictionary = {}
var _objects: Dictionary = {}
signal object_changed(event: Dictionary)


static func validate_catalog(raw: Dictionary) -> Dictionary:
    var errors: Array[String] = []
    for key in raw.keys():
        if not CATALOG_KEYS.has(String(key)):
            errors.append("unknown catalog key: %s" % key)
    if (typeof(raw.get("version")) != TYPE_INT and typeof(raw.get("version")) != TYPE_FLOAT) or not is_equal_approx(float(raw.get("version")), 1.0):
        errors.append("version must be integer 1")
    if typeof(raw.get("objects")) != TYPE_ARRAY or raw.get("objects").is_empty():
        errors.append("objects must be a non-empty array")
        return {"ok": false, "error": "; ".join(errors)}

    var ids: Dictionary = {}
    var segmentation_ids: Dictionary = {}
    for index in raw["objects"].size():
        var definition = raw["objects"][index]
        if typeof(definition) != TYPE_DICTIONARY:
            errors.append("objects[%d] must be an object" % index)
            continue
        for key in definition.keys():
            if not OBJECT_KEYS.has(String(key)):
                errors.append("objects[%d] unknown key: %s" % [index, key])
        var object_id := String(definition.get("id", ""))
        if object_id.is_empty():
            errors.append("objects[%d] id is required" % index)
        elif ids.has(object_id):
            errors.append("duplicate catalog id: %s" % object_id)
        else:
            ids[object_id] = true
        var resource := String(definition.get("resource", ""))
        if not ALLOWED_RESOURCES.has(resource):
            errors.append("objects[%d] resource is not approved: %s" % [index, resource])
        for required in ["provenance", "license"]:
            if String(definition.get(required, "")).is_empty():
                errors.append("objects[%d] %s is required" % [index, required])
        var segmentation_id = definition.get("segmentation_id")
        if (typeof(segmentation_id) != TYPE_INT and typeof(segmentation_id) != TYPE_FLOAT) or not is_equal_approx(float(segmentation_id), round(float(segmentation_id))) or int(segmentation_id) < 0 or int(segmentation_id) > 16_777_215:
            errors.append("objects[%d] segmentation_id must be a 24-bit integer" % index)
        elif segmentation_ids.has(int(segmentation_id)):
            errors.append("duplicate segmentation_id: %d" % int(segmentation_id))
        else:
            segmentation_ids[int(segmentation_id)] = true
        var size = definition.get("size")
        if not _valid_vector_array(size) or float(size[0]) <= 0.0 or float(size[1]) <= 0.0 or float(size[2]) <= 0.0:
            errors.append("objects[%d] size must contain three positive finite values" % index)
        if typeof(definition.get("collision")) != TYPE_BOOL or not bool(definition.get("collision")):
            errors.append("objects[%d] collision must be true" % index)
        if not ALLOWED_MOBILITY.has(String(definition.get("mobility", ""))):
            errors.append("objects[%d] mobility must be movable" % index)
        if typeof(definition.get("destroyable")) != TYPE_BOOL or not bool(definition.get("destroyable")):
            errors.append("objects[%d] destroyable must be true" % index)
        var bounds = definition.get("bounds")
        if typeof(bounds) != TYPE_DICTIONARY or not _valid_vector_array(bounds.get("min")) or not _valid_vector_array(bounds.get("max")):
            errors.append("objects[%d] bounds must contain finite min and max vectors" % index)
        elif not _bounds_are_ordered(bounds):
            errors.append("objects[%d] bounds min must be less than max" % index)
    if not errors.is_empty():
        return {"ok": false, "error": "; ".join(errors)}
    return {"ok": true, "catalog": raw.duplicate(true)}


static func _valid_vector_array(value) -> bool:
    if typeof(value) != TYPE_ARRAY or value.size() != 3:
        return false
    for component in value:
        if typeof(component) != TYPE_INT and typeof(component) != TYPE_FLOAT:
            return false
        if not is_finite(float(component)):
            return false
    return true


static func _bounds_are_ordered(bounds: Dictionary) -> bool:
    var minimum := Vector3(bounds["min"][0], bounds["min"][1], bounds["min"][2])
    var maximum := Vector3(bounds["max"][0], bounds["max"][1], bounds["max"][2])
    return minimum.x < maximum.x and minimum.y < maximum.y and minimum.z < maximum.z


func load_from_dictionary(raw: Dictionary) -> Dictionary:
    var validation: Dictionary = validate_catalog(raw)
    if not validation.ok:
        return validation
    reset()
    _definitions.clear()
    for definition in raw["objects"]:
        _definitions[String(definition["id"])] = definition.duplicate(true)
    return {"ok": true, "count": _definitions.size()}


func create_named(object_name: String, asset_id: String, position: Vector3, orientation: Quaternion = Quaternion(0.0, 0.0, 0.0, 1.0)) -> Dictionary:
    if not _valid_name(object_name):
        return _error("object name must match ^[A-Za-z][A-Za-z0-9_-]{0,63}$")
    if _objects.has(object_name):
        return _error("duplicate object name: %s" % object_name)
    if not _definitions.has(asset_id):
        return _error("unknown catalog asset: %s" % asset_id)
    var definition: Dictionary = _definitions[asset_id]
    if not _position_allowed(definition, position):
        return _error("object position is outside catalog bounds")
    var body := StaticBody3D.new()
    body.name = object_name
    body.position = position
    body.quaternion = orientation.normalized()
    body.set_meta("airsim_scene_object_id", asset_id)
    body.set_meta("airsim_scene_object_name", object_name)
    body.set_meta("airsim_segmentation_id", int(definition["segmentation_id"]))
    var size := Vector3(definition["size"][0], definition["size"][1], definition["size"][2])
    var collision := CollisionShape3D.new()
    collision.name = "CollisionShape3D"
    var box_shape := BoxShape3D.new()
    box_shape.size = size
    collision.shape = box_shape
    body.add_child(collision)
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "MeshInstance3D"
    var mesh := BoxMesh.new()
    mesh.size = size
    mesh_instance.mesh = mesh
    mesh_instance.set_meta("airsim_segmentation_id", int(definition["segmentation_id"]))
    body.add_child(mesh_instance)
    add_child(body)
    _objects[object_name] = {"node": body, "asset_id": asset_id}
    object_changed.emit({"action": "spawn", "name": object_name, "asset_id": asset_id, "snapshot": _object_snapshot(object_name)})
    return {"ok": true, "object": _object_snapshot(object_name)}


func move_named(object_name: String, position: Vector3, orientation: Quaternion = Quaternion(0.0, 0.0, 0.0, 1.0)) -> Dictionary:
    if not _objects.has(object_name):
        return _error("unknown object: %s" % object_name)
    var entry: Dictionary = _objects[object_name]
    var definition: Dictionary = _definitions[entry["asset_id"]]
    if not _position_allowed(definition, position):
        return _error("object position is outside catalog bounds")
    var body: StaticBody3D = entry["node"]
    body.position = position
    body.quaternion = orientation.normalized()
    object_changed.emit({"action": "move", "name": object_name, "snapshot": _object_snapshot(object_name)})
    return {"ok": true, "object": _object_snapshot(object_name)}


func query_named(object_name: String) -> Dictionary:
    if not _objects.has(object_name):
        return _error("unknown object: %s" % object_name)
    return {"ok": true, "object": _object_snapshot(object_name)}


func destroy_named(object_name: String) -> Dictionary:
    if not _objects.has(object_name):
        return _error("unknown object: %s" % object_name)
    var entry: Dictionary = _objects[object_name]
    var body: Node = entry["node"]
    _objects.erase(object_name)
    body.free()
    object_changed.emit({"action": "destroy", "name": object_name})
    return {"ok": true}


func list_named() -> Array:
    var names: Array = _objects.keys()
    names.sort()
    return names


func reset() -> void:
    var reset_names: Array = list_named()
    for object_name in _objects.keys().duplicate():
        var body: Node = _objects[object_name]["node"]
        body.free()
    _objects.clear()
    if not reset_names.is_empty():
        object_changed.emit({"action": "reset", "names": reset_names})


func _object_snapshot(object_name: String) -> Dictionary:
    var entry: Dictionary = _objects[object_name]
    var definition: Dictionary = _definitions[entry["asset_id"]]
    var body: StaticBody3D = entry["node"]
    return {
        "name": object_name,
        "asset_id": entry["asset_id"],
        "position": body.position,
        "orientation": body.transform.basis.get_rotation_quaternion(),
        "segmentation_id": int(definition["segmentation_id"]),
        "collision": body.get_child_count() >= 2,
    }


func _position_allowed(definition: Dictionary, position: Vector3) -> bool:
    if not position.is_finite():
        return false
    var bounds: Dictionary = definition["bounds"]
    var minimum := Vector3(bounds["min"][0], bounds["min"][1], bounds["min"][2])
    var maximum := Vector3(bounds["max"][0], bounds["max"][1], bounds["max"][2])
    return position.x >= minimum.x and position.x <= maximum.x and position.y >= minimum.y and position.y <= maximum.y and position.z >= minimum.z and position.z <= maximum.z


func _valid_name(object_name: String) -> bool:
    return RegEx.create_from_string("^[A-Za-z][A-Za-z0-9_-]{0,63}$").search(object_name) != null


func _error(message: String) -> Dictionary:
    return {"ok": false, "error": message}
