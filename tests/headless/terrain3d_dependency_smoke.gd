extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    if not ClassDB.class_exists("Terrain3D"):
        push_error("Terrain3D GDExtension class is unavailable")
        quit(1)
        return
    var camera := Camera3D.new()
    camera.current = true
    root.add_child(camera)
    var terrain: Node3D = ClassDB.instantiate("Terrain3D") as Node3D
    if terrain == null:
        push_error("Terrain3D must instantiate as Node3D")
        quit(1)
        return
    root.add_child(terrain)
    await process_frame
    terrain.queue_free()
    camera.queue_free()
    await process_frame
    quit(0)
