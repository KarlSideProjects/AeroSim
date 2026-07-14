extends SceneTree

const IndustrialYardScene = preload("res://levels/free_flight/industrial_yard.tscn")

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene := IndustrialYardScene.instantiate()
    if scene == null:
        push_error("Industrial Yard scene did not instantiate")
        quit(1)
        return
    root.add_child(scene)
    await process_frame
    for node_name in ["Ground", "GroundCollision", "SpawnNorth", "CargoContainers", "LowGate", "TurnMarker", "Tower"]:
        if scene.get_node_or_null(node_name) == null:
            push_error("Industrial Yard scene is missing %s" % node_name)
            quit(1)
            return
    scene.queue_free()
    quit(0)
