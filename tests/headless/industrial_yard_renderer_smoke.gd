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
    var visual_assets := scene.get_node_or_null("YardVisualAssets") as Node3D
    if visual_assets == null or visual_assets.find_children("*", "MeshInstance3D", true, false).size() < 5:
        push_error("Industrial Yard scene must load its Kenney visual asset set")
        quit(1)
        return
    for mesh_instance in visual_assets.find_children("*", "MeshInstance3D", true, false):
        var untextured := _untextured_surface(mesh_instance as MeshInstance3D)
        if untextured >= 0:
            push_error("Industrial Yard visual asset %s surface %d renders untextured" % [mesh_instance.name, untextured])
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

## Returns the index of the first surface that would render as a white model,
## or -1 when every surface carries an albedo texture.
##
## The Kenney kit ships both `.glb` sources and pre-baked `.scn` scenes; the
## latter lost their albedo textures, so a scene that referenced them rendered
## solid white while every structural assertion still passed.
func _untextured_surface(mesh_instance: MeshInstance3D) -> int:
    var mesh := mesh_instance.mesh if mesh_instance != null else null
    if mesh == null:
        return 0
    for surface in mesh.get_surface_count():
        var material := mesh_instance.get_surface_override_material(surface)
        if material == null:
            material = mesh.surface_get_material(surface)
        var base_material := material as BaseMaterial3D
        if base_material == null or base_material.albedo_texture == null:
            return surface
    return -1
