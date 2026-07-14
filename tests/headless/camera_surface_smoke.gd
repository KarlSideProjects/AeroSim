extends SceneTree

const AirSimCameraSurface = preload("res://common/rpc/airsim_camera_surface.gd")
const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const IndustrialYardScene = preload("res://levels/free_flight/industrial_yard.tscn")

var camera: Camera3D
var body: Node3D


func _initialize() -> void:
    call_deferred("_run")


func _source_camera() -> Camera3D:
    return camera


func _vehicle_body(_vehicle_name: String) -> Node3D:
    return body


func _world_origin() -> Vector3:
    return Vector3(1, 0, 2)


func _run() -> void:
    var world := Node3D.new()
    root.add_child(world)
    var map := IndustrialYardScene.instantiate()
    world.add_child(map)
    camera = Camera3D.new()
    camera.position = Vector3(0, 8, 12)
    world.add_child(camera)
    camera.look_at(Vector3(0, 0, 0), Vector3.UP)
    body = Node3D.new()
    body.position = Vector3(2, 3, 4)
    world.add_child(body)
    var surface := AirSimCameraSurface.new()
    world.add_child(surface)
    surface.configure(world, Callable(self, "_source_camera"), Callable(self, "_vehicle_body"), AirSimSession.new(), {
        "Vehicles": {"": {"Cameras": {"front_center": {
            "X": 1.0, "Y": 2.0, "Z": -3.0, "Pitch": 10.0, "Roll": 20.0, "Yaw": 30.0,
        }}}},
    }, Callable(self, "_world_origin"))
    await process_frame
    await process_frame
    var result: Dictionary = surface.capture([
        {"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false},
        {"camera_name": "0", "image_type": 5, "pixels_as_float": false, "compress": false},
    ], "", false)
    if not result.ok:
        push_error("camera surface smoke failed: %s" % result.error)
        quit(1)
        return
    var responses: Array = result.responses
    if responses.size() != 2 or responses[0].image_data_float.size() != 256 * 144 or responses[1].image_data_uint8.size() != 256 * 144 * 3:
        push_error("camera surface smoke returned malformed dimensions")
        quit(1)
        return
    var nonzero_depth := false
    for value in responses[0].image_data_float:
        if float(value) > 0.0:
            nonzero_depth = true
            break
    if not nonzero_depth:
        push_error("camera surface smoke returned no planar depth hits")
        quit(1)
        return
    var nonzero_segmentation := false
    for offset in range(0, responses[1].image_data_uint8.size(), 3):
        if responses[1].image_data_uint8[offset] != 0 or responses[1].image_data_uint8[offset + 1] != 0 or responses[1].image_data_uint8[offset + 2] != 0:
            nonzero_segmentation = true
            break
    if not nonzero_segmentation:
        push_error("camera surface smoke returned no segmentation IDs")
        quit(1)
        return
    var configured: Dictionary = surface.capture([
        {"camera_name": "front_center", "image_type": 1, "pixels_as_float": true, "compress": false},
    ], "", false)
    if not configured.ok:
        push_error("configured camera smoke failed: %s" % configured.error)
        quit(1)
        return
    var configured_position: Dictionary = configured.responses[0].camera_position
    if absf(float(configured_position.x_val) - 2.0) > 0.001 or absf(float(configured_position.y_val) - 4.0) > 0.001 or absf(float(configured_position.z_val) + 6.0) > 0.001:
        push_error("configured camera smoke returned the wrong NED camera origin")
        quit(1)
        return
    surface.queue_free()
    world.queue_free()
    quit(0)
