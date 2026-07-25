extends SceneTree

const TerrainRange = preload("res://levels/free_flight/terrain3d_range.tscn")

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
