extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")

class SmokeLicenseProvider:
    extends Node

    func get_snapshot() -> Dictionary:
        return {"ok": true, "status": "online_valid", "last_online_result": "terrain3d-runtime-smoke"}

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene := SmokeScene.instantiate()
    root.add_child(scene)
    await process_frame
    if scene.native == null:
        push_error("Terrain3D runtime smoke must instantiate AeroSimNative")
        quit(1)
        return
    if scene.license_provider != null:
        scene.license_provider.queue_free()
    var license_provider := SmokeLicenseProvider.new()
    scene.license_provider = license_provider
    scene.add_child(license_provider)
    scene.show_main_menu()
    scene.quick_fly()
    await process_frame
    if scene.loaded_map_id != "terrain3d_range" or scene.loaded_map == null or scene.get_node_or_null("LoadedMap/Terrain3D") == null:
        push_error("Quick Fly must load Terrain Range with Terrain3D")
        quit(1)
        return
    var spawn := scene.loaded_map.get_node("SpawnNorth") as Marker3D
    if scene.drone_body.global_position.distance_to(spawn.global_position) > 1e-6:
        push_error("Terrain3D runtime smoke must reset to SpawnNorth: body=%s spawn=%s" % [scene.drone_body.global_position, spawn.global_position])
        quit(1)
        return
    scene.takeoff_requested = true
    scene.drone_body.freeze = false
    scene.drone_body.sleeping = false
    if not scene.native.call("arm_flight_control", 0.0):
        push_error("Terrain3D runtime smoke must arm from low throttle")
        quit(1)
        return
    for _frame in range(60):
        await physics_frame
    scene.queue_free()
    await process_frame
    quit(0)
