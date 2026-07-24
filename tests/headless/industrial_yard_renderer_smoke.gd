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
    for node_name in ["Ground", "GroundCollision", "SpawnNorth", "SpawnSouth", "CargoContainers", "LowGate", "TurnMarker", "Tower", "TimeTrial"]:
        if scene.get_node_or_null(node_name) == null:
            push_error("Industrial Yard scene is missing %s" % node_name)
            quit(1)
            return
    for checkpoint_name in ["Checkpoint01", "Checkpoint02", "Checkpoint03"]:
        var checkpoint := scene.get_node("TimeTrial/%s" % checkpoint_name) as Marker3D
        if checkpoint == null or checkpoint.get_node_or_null("DirectionArrow") == null:
            push_error("Industrial Yard renderer scene is missing route marker %s" % checkpoint_name)
            quit(1)
            return
    if scene.get_node_or_null("TimeTrial/Finish") == null:
        push_error("Industrial Yard renderer scene is missing Finish marker")
        quit(1)
        return
    scene.queue_free()
    quit(0)
