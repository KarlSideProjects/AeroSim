extends SceneTree

const TerrainRange = preload("res://levels/free_flight/terrain3d_range.tscn")
const TerrainAssets = preload("res://assets/third_party/terrain3d_demo/demo/data/assets.tres")

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var camera := Camera3D.new()
    camera.position = Vector3(0, 30, 30)
    camera.current = true
    root.add_child(camera)
    var scene := TerrainRange.instantiate() as Node3D
    var terrain := scene.get_node_or_null("Terrain3D") as Node3D if scene != null else null
    if terrain == null:
        push_error("Terrain3D range must instantiate with a Terrain3D node")
        quit(1)
        return
    root.add_child(scene)
    await process_frame
    camera.look_at(Vector3.ZERO, Vector3.UP)
    terrain.call("set_camera", camera)
    await process_frame
    var material_layers := {}
    for texture_id in TerrainAssets.get_texture_count():
        var texture := TerrainAssets.get_texture(texture_id) as Terrain3DTextureAsset
        if texture != null:
            material_layers[texture.name] = texture
    for layer_name in ["Grass", "SoilSand", "Rock"]:
        var layer := material_layers.get(layer_name) as Terrain3DTextureAsset
        if layer == null or layer.albedo_texture == null:
            push_error("Terrain3D range must provide a textured %s ground layer" % layer_name)
            quit(1)
            return
    var grass_color := (material_layers["Grass"] as Terrain3DTextureAsset).albedo_color
    var soil_sand_color := (material_layers["SoilSand"] as Terrain3DTextureAsset).albedo_color
    var rock_color := (material_layers["Rock"] as Terrain3DTextureAsset).albedo_color
    if grass_color.is_equal_approx(soil_sand_color) or grass_color.is_equal_approx(rock_color) or soil_sand_color.is_equal_approx(rock_color):
        push_error("Terrain3D range ground layers must use distinct grass, soil/sand, and rock colors")
        quit(1)
        return
    var terrain_data := (terrain as Terrain3D).data
    var grass_sample := terrain_data.get_texture_id(Vector3(80, 0, -80))
    var soil_sand_sample := terrain_data.get_texture_id(Vector3(8, 0, -36))
    var rock_sample := terrain_data.get_texture_id(Vector3(24, 0, -44))
    if int(grass_sample.x) != 1 or int(soil_sand_sample.y) != 2 or int(rock_sample.y) != 0 or soil_sand_sample.z < 0.99 or rock_sample.z < 0.99:
        push_error("Terrain3D range must paint grass, soil/sand, and rock layers in the initial player-visible area")
        quit(1)
        return
    for node_name in ["GroundCollision", "SpawnNorth", "SpawnSouth", "TimeTrial/Finish"]:
        if scene.get_node_or_null(node_name) == null:
            push_error("Terrain3D range is missing %s" % node_name)
            quit(1)
            return
    var launch_platforms := [
        {"name": "SpawnNorthPlatform", "spawn": "SpawnNorth", "segmentation_id": 2},
        {"name": "SpawnSouthPlatform", "spawn": "SpawnSouth", "segmentation_id": 8},
    ]
    for launch_platform_spec in launch_platforms:
        var platform := scene.get_node_or_null(String(launch_platform_spec.name)) as StaticBody3D
        var spawn := scene.get_node(String(launch_platform_spec.spawn)) as Marker3D
        var platform_mesh := platform.get_node_or_null("Mesh") as MeshInstance3D if platform != null else null
        var platform_collision := platform.get_node_or_null("CollisionShape3D") as CollisionShape3D if platform != null else null
        var platform_shape := platform_collision.shape as BoxShape3D if platform_collision != null else null
        if platform == null or platform_mesh == null or platform_mesh.mesh == null or platform_shape == null or not platform_mesh.is_visible_in_tree():
            push_error("Terrain3D range %s must be a visible collision-bearing launch platform" % launch_platform_spec.name)
            quit(1)
            return
        if int(platform.get_meta("airsim_segmentation_id", -1)) != int(launch_platform_spec.segmentation_id):
            push_error("Terrain3D range %s must retain its stable AirSim segmentation ID" % launch_platform_spec.name)
            quit(1)
            return
        if platform.global_position.distance_to(Vector3(spawn.global_position.x, platform.global_position.y, spawn.global_position.z)) > 1e-6 or platform.global_transform.basis.y.dot(Vector3.UP) < 0.9999:
            push_error("Terrain3D range %s must be level and centered below %s" % [launch_platform_spec.name, launch_platform_spec.spawn])
            quit(1)
            return
        var hit := scene.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(spawn.global_position, spawn.global_position + Vector3.DOWN * 2.0))
        if hit.get("collider") != platform:
            push_error("Terrain3D range %s must provide external collision clearance below %s" % [launch_platform_spec.name, launch_platform_spec.spawn])
            quit(1)
            return
    for spawn_name in ["SpawnNorth", "SpawnSouth"]:
        var spawn := scene.get_node(spawn_name) as Marker3D
        var hit: Vector3 = terrain.call("get_intersection", Vector3(spawn.position.x, 50, spawn.position.z), Vector3.DOWN, true)
        if not is_finite(hit.x) or not is_finite(hit.y) or not is_finite(hit.z) or hit.y >= spawn.position.y:
            push_error("Terrain3D range spawn %s must clear the public terrain height" % spawn_name)
            quit(1)
            return
    for relief_sample in [Vector3(30, 0, -72), Vector3(76, 0, -48)]:
        var relief_height := terrain_data.get_height(relief_sample)
        if not is_finite(relief_height) or relief_height < 3.0:
            push_error("Terrain3D range must provide readable terrain relief beyond the launch platform")
            quit(1)
            return
    for safe_marker_name in ["SpawnNorth", "SpawnSouth", "TimeTrial/Checkpoint01", "TimeTrial/Checkpoint02", "TimeTrial/Checkpoint03", "TimeTrial/Finish"]:
        var safe_marker := scene.get_node(safe_marker_name) as Marker3D
        var terrain_height := terrain_data.get_height(safe_marker.global_position)
        if not is_finite(terrain_height) or terrain_height >= safe_marker.global_position.y:
            push_error("Terrain3D range must keep %s above the terrain relief" % safe_marker_name)
            quit(1)
            return
    for landmark_name in ["NorthRidgeRock", "EastRidgeRock"]:
        var landmark := scene.get_node_or_null(landmark_name) as StaticBody3D
        var landmark_mesh := landmark.get_node_or_null("Mesh") as MeshInstance3D if landmark != null else null
        var landmark_collision := landmark.get_node_or_null("CollisionShape3D") as CollisionShape3D if landmark != null else null
        if landmark == null or landmark_mesh == null or landmark_mesh.mesh == null or not landmark_mesh.is_visible_in_tree() or landmark_collision == null or landmark_collision.shape == null:
            push_error("Terrain3D range landmark %s must be a visible collision-bearing scene prop" % landmark_name)
            quit(1)
            return
    if not scene.find_children("*", "RigidBody3D", true, false).is_empty():
        push_error("Terrain3D range landmarks must not introduce rigid bodies")
        quit(1)
        return
    scene.queue_free()
    camera.queue_free()
    await process_frame
    quit(0)
