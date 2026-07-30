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
    # The reset pose is applied from the RigidBody physics callback and is
    # published only after its ACK. Match the runtime's bounded ACK window.
    for _frame in range(9):
        if scene._reset_pending_token == 0:
            break
        await physics_frame
    if scene._reset_pending_token != 0:
        push_error("Terrain3D runtime smoke reset did not commit: %s" % scene.last_error_message)
        quit(1)
        return
    if scene.loaded_map_id != "terrain3d_range" or scene.loaded_map == null or scene.get_node_or_null("LoadedMap/Terrain3D") == null:
        push_error("Quick Fly must load Terrain Range with Terrain3D")
        quit(1)
        return
    var particle_grid: Node = scene.loaded_map.get_node_or_null("Terrain3D/Terrain3DParticles")
    var particles: Array[Node] = particle_grid.get_children() if particle_grid != null else []
    if particles.size() != 25 or not particles.all(func(node: Node) -> bool: return node is GPUParticles3D and (node as GPUParticles3D).custom_aabb.size.x >= 25.5 and (node as GPUParticles3D).custom_aabb.size.z >= 25.5):
        push_error("Terrain Range grass must expand every existing particle-cell bound for capped blade deformation")
        quit(1)
        return
    var visual_wind: Node = scene.loaded_map.get_node_or_null("VisualWindController")
    if visual_wind == null or not visual_wind.has_method("snapshot"):
        push_error("Terrain3D runtime smoke requires the Terrain Range visual-wind snapshot seam")
        quit(1)
        return
    var before_selection: Dictionary = visual_wind.call("snapshot")
    scene.select_map("terrain3d_range", "light")
    if visual_wind.call("snapshot") != before_selection:
        push_error("Terrain Range visual wind must not sample before an authoritative frame advances")
        quit(1)
        return
    await physics_frame
    var light_snapshot: Dictionary = visual_wind.call("snapshot")
    var light_target: Vector2 = light_snapshot.target_horizontal_wind
    if light_target.x >= 0.0 or light_target.y <= 0.0 or light_target.length() < 1.5 or light_target.length() > 2.5:
        push_error("Terrain Range Light visual wind must be bounded and flow from -X toward +Z")
        quit(1)
        return
    var explicit_steady := Vector3(3.0, 0.0, -4.0)
    var explicit_environment: Dictionary = scene._airsim_environment("simSetEnvironment", [{"steady_wind": {"x_val": explicit_steady.x, "y_val": explicit_steady.y, "z_val": explicit_steady.z}, "wind_preset": "severe"}])
    if not explicit_environment.ok:
        push_error("Terrain3D runtime smoke must accept an explicit steady wind")
        quit(1)
        return
    var preset_only_environment: Dictionary = scene._airsim_environment("simSetEnvironment", [{"wind_preset": "light"}])
    var native_wind: Dictionary = scene.native.call("wind_configuration")
    if not preset_only_environment.ok or native_wind.steady_wind != explicit_steady:
        push_error("Preset-only RPC wind updates must preserve an explicit steady wind vector")
        quit(1)
        return
    var frozen_snapshot: Dictionary = visual_wind.call("snapshot")
    scene.screen = "flight"
    var pause_action := InputEventAction.new()
    pause_action.action = &"flight_pause"
    pause_action.pressed = true
    scene._unhandled_input(pause_action)
    await physics_frame
    await process_frame
    var reset_button := scene.get_node_or_null("FlightHud/PausePanel/Rows/Reset") as Button
    var frozen: bool = visual_wind.call("snapshot") == frozen_snapshot
    if not scene.paused or reset_button == null or not frozen:
        push_error("Terrain Range visual wind must freeze through the player pause action")
        quit(1)
        return
    reset_button.pressed.emit()
    var reset_snapshot: Dictionary = visual_wind.call("snapshot")
    if scene._reset_pending_token == 0:
        push_error("Terrain3D runtime smoke Reset must enter reset-pending before visual wind can resume")
        quit(1)
        return
    scene._advance_visual_wind(true)
    if visual_wind.call("snapshot") != reset_snapshot:
        push_error("Terrain Range visual wind must freeze while the player Reset is pending")
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
