extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const TRIALS := 200
const MAX_WAIT_PHYSICS_FRAMES := 600

class BenchmarkLicenseProvider:
    extends Node

    func get_snapshot() -> Dictionary:
        return {"ok": true, "status": "online_valid", "last_online_result": "reset_respawn_benchmark"}

var output_path := "build/reset_respawn_raw.json"
var commit_sha := ""
var godot_version := ""
var godot_sha256 := ""
var godot_cpp_revision := ""
var gdextension_sha256 := ""
var native_source_sha256 := ""
var required_adapter := "NVIDIA"
var failure := ""

func _initialize() -> void:
    _parse_args()
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    _run()

func _run() -> void:
    await process_frame
    await process_frame
    if not _valid_provenance():
        _fail("complete benchmark provenance is required")
        return
    var adapter := RenderingServer.get_video_adapter_name()
    if adapter.is_empty() or (not required_adapter.is_empty() and not adapter.to_lower().contains(required_adapter.to_lower())):
        _fail("required GPU adapter %s was not selected: %s" % [required_adapter, adapter])
        return
    if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
        _fail("VSync could not be disabled")
        return
    if str(ProjectSettings.get_setting("physics/3d/physics_engine")) != "Jolt Physics":
        _fail("GPU-A reset benchmark requires Jolt Physics")
        return

    var runtime = SmokeScene.instantiate()
    root.add_child(runtime)
    await process_frame
    if runtime.native == null or root.get_camera_3d() == null:
        _fail("headed reset benchmark requires AeroSimNative and an active Camera3D")
        return
    _install_license(runtime)
    var device_id := await _inject_known_gamepad()
    if device_id < 0:
        _fail("benchmark requires a known virtual SDL controller")
        return
    runtime.quick_fly()
    await process_frame
    if runtime.screen == "controller_confirmation":
        runtime.accept_controller_confirmation()
        await process_frame
    if runtime.screen != "preflight" or runtime.session_gamepad_profile == null:
        _fail("benchmark must enter low-throttle preflight with the Xbox default profile")
        return
    runtime.arm_and_takeoff()
    _send_throttle(device_id, 0.75)
    for _frame in range(Engine.physics_ticks_per_second / 4):
        await physics_frame

    var plain_samples: Array[float] = []
    var overlay_samples: Array[float] = []
    for _trial in range(TRIALS):
        var plain_elapsed := await _measure_plain_x_reset(runtime, device_id)
        plain_samples.append(plain_elapsed)
        if plain_elapsed < 0.0:
            _fail("plain X Reset did not reach the telemetry endpoint")
            break
    if failure.is_empty():
        for _trial in range(TRIALS):
            var overlay_elapsed := await _measure_overlay_reset(runtime)
            overlay_samples.append(overlay_elapsed)
            if overlay_elapsed < 0.0:
                _fail("Pause Overlay Reset did not reach the telemetry endpoint")
                break

    var report := {
        "schema_version": 1,
        "gate": "G4B.2/G4B.UI3",
        "sample_count": plain_samples.size() + overlay_samples.size(),
        "trials_per_path": TRIALS,
        "samples_ms": {"plain_x_reset": plain_samples, "pause_overlay_reset": overlay_samples},
        "p99_ms": {"plain_x_reset": _p99(plain_samples), "pause_overlay_reset": _p99(overlay_samples)},
        "endpoint_contract": {
            "armed_preserved": true,
            "pause_off": true,
            "nonzero_throttle_accepted_by_native_telemetry": true,
            "max_wait_physics_frames": MAX_WAIT_PHYSICS_FRAMES,
        },
        "commit_sha": commit_sha,
        "godot_version": godot_version,
        "godot_sha256": godot_sha256,
        "godot_cpp_revision": godot_cpp_revision,
        "gdextension_sha256": gdextension_sha256,
        "native_source_sha256": native_source_sha256,
        "video_adapter": adapter,
        "rendering_method": RenderingServer.get_current_rendering_method(),
        "physics_engine": ProjectSettings.get_setting("physics/3d/physics_engine"),
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "failure": failure,
    }
    _write_report(report)
    runtime.queue_free()
    quit(1 if not failure.is_empty() else 0)

func _measure_plain_x_reset(runtime: Node, device_id: int) -> float:
    _send_throttle(device_id, 0.75)
    await process_frame
    var before: int = runtime.reset_count
    var started_us := Time.get_ticks_usec()
    var x := InputEventJoypadButton.new()
    x.device = device_id
    x.button_index = JOY_BUTTON_X
    x.pressed = true
    Input.parse_input_event(x)
    x.pressed = false
    Input.parse_input_event(x)
    return await _wait_for_endpoint(runtime, before, started_us)

func _measure_overlay_reset(runtime: Node) -> float:
    runtime.set_paused(true)
    await process_frame
    var reset_button := runtime.get_node_or_null("FlightHud/PausePanel/Rows/Reset") as Button
    if reset_button == null:
        return -1.0
    var before: int = runtime.reset_count
    var started_us := Time.get_ticks_usec()
    reset_button.pressed.emit()
    return await _wait_for_endpoint(runtime, before, started_us)

func _wait_for_endpoint(runtime: Node, reset_count_before: int, started_us: int) -> float:
    for _frame in range(MAX_WAIT_PHYSICS_FRAMES):
        await physics_frame
        if runtime.reset_count <= reset_count_before or runtime.paused or not runtime._flight_control_armed():
            continue
        var snapshot: Dictionary = runtime.native.call("telemetry_snapshot")
        var thrust := 0.0
        for motor in snapshot.get("motors", []):
            thrust += float(motor.get("thrust_newtons", 0.0))
        if runtime.reset_hold_frames <= 0 and thrust > 0.0:
            return float(Time.get_ticks_usec() - started_us) / 1000.0
    return -1.0

func _send_throttle(device_id: int, value: float) -> void:
    var throttle := InputEventJoypadMotion.new()
    throttle.device = device_id
    throttle.axis = JOY_AXIS_RIGHT_Y
    throttle.axis_value = value
    Input.parse_input_event(throttle)

func _p99(samples: Array[float]) -> float:
    if samples.is_empty():
        return -1.0
    var ordered := samples.duplicate()
    ordered.sort()
    return float(ordered[mini(ordered.size() - 1, maxi(0, ceili(ordered.size() * 0.99) - 1))])

func _install_license(runtime: Node) -> void:
    if runtime.license_provider != null:
        runtime.remove_child(runtime.license_provider)
        runtime.license_provider.queue_free()
    var provider := BenchmarkLicenseProvider.new()
    runtime.license_provider = provider
    runtime.add_child(provider)
    runtime.show_main_menu()

func _inject_known_gamepad() -> int:
    var event := InputEventJoypadMotion.new()
    event.device = 0
    event.axis = JOY_AXIS_LEFT_X
    event.axis_value = 0.5
    Input.parse_input_event(event)
    await process_frame
    for device_id in Input.get_connected_joypads():
        if Input.is_joy_known(device_id):
            return device_id
    return -1

func _valid_provenance() -> bool:
    return commit_sha.length() == 40 and not godot_version.is_empty() and godot_sha256.length() == 64 and godot_cpp_revision.length() == 40 and gdextension_sha256.length() == 64 and native_source_sha256.length() == 64

func _parse_args() -> void:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        match args[index]:
            "--output": output_path = args[index + 1]
            "--commit-sha": commit_sha = args[index + 1]
            "--godot-version": godot_version = args[index + 1]
            "--godot-sha256": godot_sha256 = args[index + 1]
            "--godot-cpp-revision": godot_cpp_revision = args[index + 1]
            "--gdextension-sha256": gdextension_sha256 = args[index + 1]
            "--native-source-sha256": native_source_sha256 = args[index + 1]
            "--require-adapter": required_adapter = args[index + 1]

func _write_report(report: Dictionary) -> void:
    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write reset benchmark output: %s" % output_path)
        return
    file.store_string(JSON.stringify(report))
    file.close()

func _fail(message: String) -> void:
    failure = message
    push_error(message)
