class_name AirSimCameraSurface
extends Node

const AirSimCoordinateContract = preload("res://common/rpc/airsim_coordinate_contract.gd")

const IMAGE_SCENE := 0
const IMAGE_DEPTH_PLANAR := 1
const IMAGE_SEGMENTATION := 5
const DEFAULT_WIDTH := 256
const DEFAULT_HEIGHT := 144
const MAX_DEPTH_METERS := 1000.0
const SUPPORTED_IMAGE_TYPES := [IMAGE_SCENE, IMAGE_DEPTH_PLANAR, IMAGE_SEGMENTATION]
const CATALOG_PATH := "res://config/maps/industrial_yard.json"

var _world_root: Node3D
var _source_camera_provider: Callable
var _vehicle_body_provider: Callable
var _world_origin_provider: Callable
var _session
var _settings: Dictionary = {}
var _render_viewport: SubViewport
var _render_camera: Camera3D


func configure(
        world_root: Node3D,
        source_camera_provider: Callable,
        vehicle_body_provider: Callable,
        session,
        settings: Dictionary,
        world_origin_provider: Callable = Callable()) -> void:
    _world_root = world_root
    _source_camera_provider = source_camera_provider
    _vehicle_body_provider = vehicle_body_provider
    _world_origin_provider = world_origin_provider
    _session = session
    _settings = settings.duplicate(true)


func capture(requests: Array, vehicle_name: String, _external: bool = false) -> Dictionary:
    if _world_root == null or not is_instance_valid(_world_root):
        return {"ok": false, "error": "camera world is unavailable"}
    var normalized: Array = []
    for request in requests:
        var checked := _validate_request(request)
        if not checked.ok:
            return checked
        normalized.append(checked.request)
    if normalized.is_empty():
        return {"ok": true, "responses": []}

    var camera_result := _prepare_camera(normalized[0], vehicle_name)
    if not camera_result.ok:
        return camera_result
    var camera: Camera3D = camera_result.camera
    var image_cache: Dictionary = {}
    var geometry_cache: Dictionary = {}
    var responses: Array = []
    for request in normalized:
        if not _same_camera_request(request, normalized[0]):
            camera_result = _prepare_camera(request, vehicle_name)
            if not camera_result.ok:
                return camera_result
            camera = camera_result.camera
        var response := _capture_request(request, camera, image_cache, geometry_cache, vehicle_name)
        if not response.ok:
            return response
        responses.append(response.response)
    return {"ok": true, "responses": responses}


func catalog_metadata() -> Array:
    var file := FileAccess.open(CATALOG_PATH, FileAccess.READ)
    if file == null:
        return []
    var parsed = JSON.parse_string(file.get_as_text())
    if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("segmentation_objects")) != TYPE_ARRAY:
        return []
    return parsed["segmentation_objects"].duplicate(true)


func _validate_request(request: Variant) -> Dictionary:
    if typeof(request) != TYPE_DICTIONARY:
        return {"ok": false, "error": "simGetImages requests must be an array of ImageRequest maps"}
    if typeof(request.get("camera_name")) != TYPE_STRING:
        return {"ok": false, "error": "ImageRequest.camera_name must be a string"}
    if typeof(request.get("image_type")) != TYPE_INT:
        return {"ok": false, "error": "ImageRequest.image_type must be an integer"}
    if typeof(request.get("pixels_as_float")) != TYPE_BOOL or typeof(request.get("compress")) != TYPE_BOOL:
        return {"ok": false, "error": "ImageRequest pixels_as_float and compress must be boolean"}
    var image_type := int(request["image_type"])
    if image_type not in SUPPORTED_IMAGE_TYPES:
        return {"ok": false, "error": "unsupported image type %d; supported types are Scene(0), DepthPlanar(1), and Segmentation(5)" % image_type}
    if image_type == IMAGE_DEPTH_PLANAR and not bool(request["pixels_as_float"]):
        return {"ok": false, "error": "DepthPlanar requires pixels_as_float=true"}
    if image_type != IMAGE_DEPTH_PLANAR and bool(request["pixels_as_float"]):
        return {"ok": false, "error": "Scene and Segmentation require pixels_as_float=false"}
    if String(request["camera_name"]).is_empty():
        return {"ok": false, "error": "ImageRequest.camera_name must not be empty"}
    var normalized: Dictionary = request.duplicate(true)
    normalized["camera_name"] = String(normalized["camera_name"])
    return {"ok": true, "request": normalized}


func _prepare_camera(request: Dictionary, vehicle_name: String) -> Dictionary:
    if _render_viewport == null:
        _render_viewport = SubViewport.new()
        _render_viewport.name = "AirSimCameraRenderTarget"
        _render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
        _render_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
        _render_viewport.transparent_bg = false
        add_child(_render_viewport)
        _render_camera = Camera3D.new()
        _render_camera.name = "AirSimCamera"
        _render_camera.near = 0.05
        _render_camera.far = MAX_DEPTH_METERS
        _render_viewport.add_child(_render_camera)
    if _world_root.get_viewport() == null or _world_root.get_viewport().world_3d == null:
        return {"ok": false, "error": "camera world has no World3D"}
    _render_viewport.world_3d = _world_root.get_viewport().world_3d
    var width := int(_capture_setting(request, "Width", DEFAULT_WIDTH, vehicle_name))
    var height := int(_capture_setting(request, "Height", DEFAULT_HEIGHT, vehicle_name))
    if width < 2 or height < 2 or width > 4096 or height > 4096:
        return {"ok": false, "error": "camera CaptureSettings dimensions must be from 2 to 4096 pixels"}
    _render_viewport.size = Vector2i(width, height)
    var source_camera: Camera3D = null
    if _source_camera_provider.is_valid():
        source_camera = _source_camera_provider.call(vehicle_name) if _source_camera_provider.get_argument_count() > 0 else _source_camera_provider.call()
    if source_camera == null or not is_instance_valid(source_camera):
        return {"ok": false, "error": "camera source is unavailable"}
    _render_camera.global_transform = source_camera.global_transform
    _render_camera.fov = float(_capture_setting(request, "FOV_Degrees", source_camera.fov, vehicle_name))
    var body = _vehicle_body_provider.call(vehicle_name) if _vehicle_body_provider.is_valid() else null
    var camera_settings := _camera_settings(vehicle_name, String(request["camera_name"]))
    if body != null and not camera_settings.is_empty():
        var offset_ned := Vector3(
            float(camera_settings.get("X", 0.0)),
            float(camera_settings.get("Y", 0.0)),
            float(camera_settings.get("Z", 0.0)))
        _render_camera.global_position = body.global_position + body.global_basis * AirSimCoordinateContract.ned_direction_to_godot(offset_ned)
        var pitch := deg_to_rad(float(camera_settings.get("Pitch", 0.0)))
        var roll := deg_to_rad(float(camera_settings.get("Roll", 0.0)))
        var yaw := deg_to_rad(float(camera_settings.get("Yaw", 0.0)))
        var relative_orientation := AirSimCoordinateContract.ned_orientation_to_godot(Quaternion.from_euler(Vector3(roll, pitch, yaw)))
        _render_camera.global_basis = body.global_basis * Basis(relative_orientation)
    _render_camera.current = true
    return {"ok": true, "camera": _render_camera}


func _capture_request(request: Dictionary, camera: Camera3D, image_cache: Dictionary, geometry_cache: Dictionary, vehicle_name: String) -> Dictionary:
    var image_type := int(request["image_type"])
    var width := _render_viewport.size.x
    var height := _render_viewport.size.y
    var response := _response_header(request, camera, width, height, vehicle_name)
    if image_type == IMAGE_DEPTH_PLANAR:
        var geometry := _geometry(camera, width, height, geometry_cache)
        response["image_data_float"] = _flip_float_rows(geometry.depth, width, height)
        return {"ok": true, "response": response}
    if image_type == IMAGE_SEGMENTATION:
        var segmentation := _segmentation_image(camera, width, height, geometry_cache)
        response["image_data_uint8"] = segmentation.save_png_to_buffer() if bool(request["compress"]) else segmentation.get_data()
        return {"ok": true, "response": response}
    var key := "%d:%d:%s" % [width, height, str(camera.global_transform)]
    if not image_cache.has(key):
        RenderingServer.force_draw()
        var image := _render_viewport.get_texture().get_image()
        if image == null or image.is_empty():
            return {"ok": false, "error": "camera render target produced no image"}
        image.convert(Image.FORMAT_RGBA8)
        image_cache[key] = image
    var scene_image: Image = image_cache[key]
    var output_image := scene_image.duplicate()
    output_image.flip_y()
    output_image.convert(Image.FORMAT_RGB8)
    response["image_data_uint8"] = output_image.save_png_to_buffer() if bool(request["compress"]) else output_image.get_data()
    return {"ok": true, "response": response}


func _response_header(request: Dictionary, camera: Camera3D, width: int, height: int, vehicle_name: String) -> Dictionary:
    var orientation := AirSimCoordinateContract.godot_orientation_to_ned(camera.global_transform.basis.get_rotation_quaternion())
    var origin: Vector3 = _world_origin_provider.call() if _world_origin_provider.is_valid() else Vector3.ZERO
    var position := AirSimCoordinateContract.godot_world_to_ned(camera.global_position, origin)
    var timestamp := int(round(float(_session.simulation_time_seconds) * 1_000_000_000.0)) if _session != null else 0
    return {
        "image_data_uint8": PackedByteArray(),
        "image_data_float": PackedFloat32Array(),
        "camera_position": {"x_val": position.x, "y_val": position.y, "z_val": position.z},
        "camera_name": String(request["camera_name"]),
        "camera_orientation": {"w_val": orientation.w, "x_val": orientation.x, "y_val": orientation.y, "z_val": orientation.z},
        "time_stamp": timestamp,
        "message": "",
        "pixels_as_float": bool(request["pixels_as_float"]),
        "compress": bool(request["compress"]),
        "width": width,
        "height": height,
        "image_type": int(request["image_type"]),
        "aerosim_identity": {"vehicle_name": vehicle_name},
    }


func _geometry(camera: Camera3D, width: int, height: int, cache: Dictionary) -> Dictionary:
    var key := "%d:%d:%s:%f:%d" % [width, height, str(camera.global_transform), camera.fov, camera.projection]
    if cache.has(key):
        return cache[key]
    var depth := PackedFloat32Array()
    var segmentation := PackedInt32Array()
    depth.resize(width * height)
    segmentation.resize(width * height)
    var space_state := _world_root.get_world_3d().direct_space_state
    for y in height:
        for x in width:
            var pixel := Vector2(float(x) + 0.5, float(y) + 0.5)
            var origin := camera.project_ray_origin(pixel)
            var direction := camera.project_ray_normal(pixel)
            var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * MAX_DEPTH_METERS)
            query.collide_with_areas = true
            var hit := space_state.intersect_ray(query)
            var index := y * width + x
            if hit.is_empty():
                depth[index] = 0.0
                segmentation[index] = 0
                continue
            depth[index] = maxf(0.0, (Vector3(hit["position"]) - origin).dot(-camera.global_transform.basis.z))
            segmentation[index] = _segmentation_id(hit.get("collider"))
    var result := {"depth": depth, "segmentation": segmentation}
    cache[key] = result
    return result


func _segmentation_image(camera: Camera3D, width: int, height: int, cache: Dictionary) -> Image:
    var geometry := _geometry(camera, width, height, cache)
    var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
    for y in height:
        for x in width:
            var id := int(geometry.segmentation[y * width + x])
            image.set_pixel(x, y, Color8(id & 0xff, (id >> 8) & 0xff, (id >> 16) & 0xff, 255))
    image.flip_y()
    image.convert(Image.FORMAT_RGB8)
    return image


func _flip_float_rows(values: PackedFloat32Array, width: int, height: int) -> PackedFloat32Array:
    var flipped := PackedFloat32Array()
    flipped.resize(values.size())
    for y in height:
        var source_row := y * width
        var destination_row := (height - y - 1) * width
        for x in width:
            flipped[destination_row + x] = values[source_row + x]
    return flipped


func _segmentation_id(collider: Variant) -> int:
    var node := collider as Node
    while node != null:
        if node.has_meta("airsim_segmentation_id"):
            return int(node.get_meta("airsim_segmentation_id"))
        node = node.get_parent()
    return 0


func _same_camera_request(left: Dictionary, right: Dictionary) -> bool:
    return left.get("camera_name") == right.get("camera_name") and left.get("image_type") == right.get("image_type") and left.get("Width", -1) == right.get("Width", -1) and left.get("Height", -1) == right.get("Height", -1)


func _camera_settings(vehicle_name: String, camera_name: String) -> Dictionary:
    var vehicles: Dictionary = _settings.get("Vehicles", {})
    var vehicle: Dictionary = vehicles.get(vehicle_name, {})
    var cameras: Dictionary = vehicle.get("Cameras", {})
    var settings = cameras.get(camera_name, {})
    return settings if typeof(settings) == TYPE_DICTIONARY else {}


func _capture_setting(request: Dictionary, key: String, default_value: Variant, vehicle_name: String) -> Variant:
    var camera_settings := _camera_settings(vehicle_name, String(request.get("camera_name", "0")))
    var captures = camera_settings.get("CaptureSettings", [])
    if typeof(captures) == TYPE_ARRAY:
        for capture in captures:
            if typeof(capture) == TYPE_DICTIONARY and int(capture.get("ImageType", -1)) == int(request.get("image_type", -1)) and capture.has(key):
                return int(capture[key]) if key in ["Width", "Height"] else float(capture[key])
    return int(default_value) if key in ["Width", "Height"] else default_value
