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
    for spawn_name in ["SpawnNorth", "SpawnSouth"]:
        var spawn := scene.get_node(spawn_name) as Marker3D
        var hit: Vector3 = terrain.call("get_intersection", Vector3(spawn.position.x, 50, spawn.position.z), Vector3.DOWN, true)
        if not is_finite(hit.x) or not is_finite(hit.y) or not is_finite(hit.z) or hit.y >= spawn.position.y:
            push_error("Terrain3D range spawn %s must clear the public terrain height" % spawn_name)
            quit(1)
            return
    scene.queue_free()
    camera.queue_free()
    await process_frame
    quit(0)
