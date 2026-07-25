extends SceneTree

const DataDirectory := "res://assets/third_party/terrain3d_demo/demo/data"
const TerrainRange = preload("res://levels/free_flight/terrain3d_range.tscn")

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var camera := Camera3D.new()
    camera.position = Vector3(0, 30, 30)
    camera.current = true
    root.add_child(camera)
    var scene := TerrainRange.instantiate() as Node3D
    var terrain := scene.get_node_or_null("Terrain3D") as Terrain3D if scene != null else null
    if terrain == null:
        push_error("Terrain Range must provide Terrain3D before generating ground data")
        quit(1)
        return
    root.add_child(scene)
    await process_frame
    camera.look_at(Vector3(32, 0, 24), Vector3.UP)
    terrain.set_camera(camera)
    var terrain_data := terrain.data
    for x in range(0, 161):
        for z in range(0, 161):
            var position := Vector3(x, 0, z)
            terrain_data.set_control_base_id(position, 1)
            terrain_data.set_control_overlay_id(position, 1)
            terrain_data.set_control_blend(position, 0.0)
            var soil_sand_weight := clampf(1.0 - (Vector2(x - 12, z - 18).length() - 10.0) / 8.0, 0.0, 1.0)
            var rock_weight := clampf(1.0 - (Vector2(x - 42, z - 24).length() - 10.0) / 8.0, 0.0, 1.0)
            if soil_sand_weight > rock_weight:
                terrain_data.set_control_overlay_id(position, 2)
                terrain_data.set_control_blend(position, soil_sand_weight)
            elif rock_weight > 0.0:
                terrain_data.set_control_overlay_id(position, 0)
                terrain_data.set_control_blend(position, rock_weight)
    terrain_data.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
    terrain_data.save_directory(DataDirectory)
    scene.queue_free()
    camera.queue_free()
    await process_frame
    quit(0)
