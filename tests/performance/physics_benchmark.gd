extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")


class PhysicsFrameProfiler:
    extends EngineProfiler

    var frame_ids: Array[int] = []
    var samples_ms: Array[float] = []

    func _tick(_frame_time: float, _process_time: float, physics_time: float, _physics_frame_time: float) -> void:
        if physics_time > 0.0:
            frame_ids.append(Engine.get_physics_frames())
            samples_ms.append(physics_time * 1000.0)


class EffectWorkload:
    extends Node

    var native: Object
    var enabled := false
    var effect_evidence: Dictionary = {}

    func configure(native_runtime: Object, effects_enabled: bool) -> bool:
        native = native_runtime
        enabled = effects_enabled
        effect_evidence = {
            "A3_drag": {"observed": false, "magnitude": 0.0},
            "A4_ground_effect": {"observed": false, "magnitude": 0.0},
            "A5_downwash": {"observed": false, "force_y_newtons": 0.0},
            "A6_propwash": {"observed": false, "magnitude": 0.0},
        }
        native.call("configure_imu", {
            "noise_enabled": false,
            "bias_enabled": false,
            "random_walk_enabled": false,
            "delay_enabled": false,
        })
        native.call("reset_flight")
        if not native.call("set_a5_downwash_model", enabled, 0.0231348, 2267.18, 0.16, -0.11):
            return false
        if not native.call("set_dual_aircraft_positions", 0.0, 2.0, 0.0, 0.0, 0.0, 0.0):
            return false
        if not native.call("arm_flight_control", 0.0):
            return false
        return _activate_a6()

    func _activate_a6() -> bool:
        if not native.call("set_a6_propwash_model", enabled, 12.0, 2.0, 0.5):
            return false
        native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.866025403784, 0.0, -6.0, 0.0, 3.0, 0.0, -4.0)
        var single_row: PackedFloat64Array = native.call("step_angle_mode", 240, 1000, 0.75, 0.0, 0.0, 0.0)
        if single_row.is_empty():
            return false
        var telemetry: Dictionary = native.call("telemetry_snapshot")
        var propwash: Vector3 = telemetry.get("propwash_disturbance_rad_s2", Vector3.ZERO)
        effect_evidence["A6_propwash"] = {
            "observed": enabled and propwash.length() > 0.0,
            "magnitude": propwash.length(),
        }
        return not enabled or propwash.length() > 0.0

    func _physics_process(_delta: float) -> void:
        if native == null:
            return
        var previous_evidence := effect_evidence.duplicate(true)
        if not _activate_a6():
            return
        var dual_row: PackedFloat64Array = native.call("step_dual_aircraft_simulation", 240, 1000, 0.72 * 9.80665)
        var telemetry: Dictionary = native.call("telemetry_snapshot")
        var drag_body: Vector3 = telemetry.get("drag_body_n", Vector3.ZERO)
        var propwash: Vector3 = telemetry.get("propwash_disturbance_rad_s2", Vector3.ZERO)
        var downwash_force := float(dual_row[8]) if dual_row.size() > 8 else 0.0
        var previous_downwash_force := float(previous_evidence.get("A5_downwash", {}).get("force_y_newtons", 0.0))
        effect_evidence = {
            "A3_drag": {
                "observed": enabled and (drag_body.length() > 0.0 or bool(previous_evidence.get("A3_drag", {}).get("observed", false))),
                "magnitude": maxf(drag_body.length(), float(previous_evidence.get("A3_drag", {}).get("magnitude", 0.0))),
            },
            "A4_ground_effect": {
                "observed": enabled and (float(telemetry.get("ground_effect_gain", 0.0)) > 0.0 or bool(previous_evidence.get("A4_ground_effect", {}).get("observed", false))),
                "magnitude": maxf(float(telemetry.get("ground_effect_gain", 0.0)), float(previous_evidence.get("A4_ground_effect", {}).get("magnitude", 0.0))),
            },
            "A5_downwash": {
                "observed": enabled and (downwash_force < 0.0 or bool(previous_evidence.get("A5_downwash", {}).get("observed", false))),
                "force_y_newtons": minf(downwash_force, previous_downwash_force),
            },
            "A6_propwash": {
                "observed": enabled and (propwash.length() > 0.0 or bool(previous_evidence.get("A6_propwash", {}).get("observed", false))),
                "magnitude": maxf(propwash.length(), float(previous_evidence.get("A6_propwash", {}).get("magnitude", 0.0))),
            },
        }

    func active_effects() -> Array[String]:
        var result: Array[String] = []
        for effect in ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"]:
            if bool(effect_evidence.get(effect, {}).get("observed", false)):
                result.append(effect)
        return result


var _output_path := "build/performance_raw.json"
var _warmup_seconds := 10.0
var _seconds := 60.0
var _effects := "off"
var _benchmark_mode := "gate"
var _required_adapter := "NVIDIA"
var _godot_version := ""
var _godot_sha256 := ""
var _godot_cpp_revision := ""
var _gdextension_sha256 := ""
var _native_source_sha256 := ""


func _initialize() -> void:
    _parse_args()
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    _run()


func _run() -> void:
    await process_frame
    await process_frame
    if _benchmark_mode != "gate" and _benchmark_mode != "reference" and _benchmark_mode != "smoke":
        _fail("benchmark mode must be gate, reference, or smoke")
        return
    if not is_finite(_warmup_seconds) or not is_finite(_seconds) or _warmup_seconds < 0.0 or _seconds <= 0.0:
        _fail("benchmark durations must be finite with non-negative warmup and positive measurement")
        return
    if _benchmark_mode != "smoke" and (_warmup_seconds != 10.0 or _seconds != 60.0):
        _fail("gate and reference modes require exactly 10s warmup and 60s measurement")
        return
    if _godot_version.is_empty() or _godot_sha256.length() != 64 or _godot_cpp_revision.length() != 40 or _gdextension_sha256.length() != 64 or _native_source_sha256.length() != 64:
        _fail("complete Godot, godot-cpp, GDExtension, and native source provenance is required")
        return
    var adapter := RenderingServer.get_video_adapter_name()
    if adapter.is_empty():
        _fail("headed benchmark did not expose a GPU adapter")
        return
    if not _required_adapter.is_empty() and not adapter.to_lower().contains(_required_adapter.to_lower()):
        _fail("required GPU adapter %s was not selected: %s" % [_required_adapter, adapter])
        return
    if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
        _fail("VSync could not be disabled")
        return
    if str(ProjectSettings.get_setting("physics/3d/physics_engine")) != "Jolt Physics":
        _fail("G0.1 requires the Jolt Physics scene")
        return
    if not EngineDebugger.is_active():
        _fail("G0.1 requires --remote-debug local:// for per-frame physics timing")
        return

    var runtime = SmokeScene.instantiate()
    root.add_child(runtime)
    await process_frame
    if runtime.native == null:
        _fail("AeroSimNative is not registered")
        return
    if root.get_camera_3d() == null:
        _fail("headed benchmark requires an active Camera3D")
        return
    if not _configure_effects(runtime.native):
        return
    var known_device_id := await _inject_known_gamepad()
    if known_device_id < 0:
        _fail("benchmark requires a known virtual SDL controller")
        return
    runtime.quick_fly()
    await process_frame
    if runtime.screen == "controller_confirmation":
        runtime.accept_controller_confirmation()
        await process_frame
    elif runtime.screen != "preflight":
        _fail("benchmark must restore or confirm the Xbox default profile before preflight")
        return
    if runtime.screen != "preflight" or runtime.session_gamepad_profile == null or runtime.takeoff_requested:
        _fail("benchmark must enter low-throttle preflight with the Xbox default profile")
        return
    runtime.arm_and_takeoff()
    var effect_workload := EffectWorkload.new()
    if not effect_workload.configure(runtime.native, _effects == "on"):
        _fail("cannot configure complete A3-A6 workload")
        return
    effect_workload.process_physics_priority = 100
    root.add_child(effect_workload)
    var physics_profiler := PhysicsFrameProfiler.new()
    EngineDebugger.register_profiler("aerosim_physics_frame", physics_profiler)
    EngineDebugger.profiler_enable("aerosim_physics_frame", true)
    var viewport_rid := root.get_viewport().get_viewport_rid()
    RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
    var warmup_frames := maxi(0, ceili(_warmup_seconds * Engine.physics_ticks_per_second))
    for _frame in warmup_frames:
        await physics_frame

    var render_cpu_samples: Array[float] = []
    var render_gpu_samples: Array[float] = []
    var frames := maxi(1, ceili(_seconds * Engine.physics_ticks_per_second))
    var first_measured_frame := Engine.get_physics_frames() + 1
    for _frame in frames:
        await physics_frame
        await process_frame
        render_cpu_samples.append(
            RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
            + RenderingServer.get_frame_setup_time_cpu()
        )
        render_gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
    var last_measured_frame := Engine.get_physics_frames()
    await process_frame

    EngineDebugger.profiler_enable("aerosim_physics_frame", false)
    EngineDebugger.unregister_profiler("aerosim_physics_frame")
    var physics_samples: Array[float] = []
    for index in physics_profiler.frame_ids.size():
        if physics_profiler.frame_ids[index] >= first_measured_frame and physics_profiler.frame_ids[index] <= last_measured_frame:
            physics_samples.append(physics_profiler.samples_ms[index])
    if physics_samples.size() != frames:
        _fail("per-frame profiler captured %d of %d physics frames" % [physics_samples.size(), frames])
        return
    if _effects == "on" and effect_workload.active_effects().size() != 4:
        _fail("enabled benchmark workload did not observe all A3-A6 effects: %s" % effect_workload.effect_evidence)
        return

    var output := FileAccess.open(_output_path, FileAccess.WRITE)
    if output == null:
        _fail("Cannot write benchmark output: %s" % _output_path)
        return
    output.store_string(JSON.stringify({
        "samples_ms": physics_samples,
        "render_cpu_samples_ms": render_cpu_samples,
        "render_gpu_samples_ms": render_gpu_samples,
        "sampling_source": "EngineProfiler._tick",
        "benchmark_mode": _benchmark_mode,
        "godot_version": _godot_version,
        "godot_sha256": _godot_sha256,
        "godot_cpp_revision": _godot_cpp_revision,
        "gdextension_sha256": _gdextension_sha256,
        "native_source_sha256": _native_source_sha256,
        "scenario": "effects_%s" % _effects,
        "active_effects": effect_workload.active_effects(),
        "effect_evidence": effect_workload.effect_evidence,
        "physics_engine": ProjectSettings.get_setting("physics/3d/physics_engine"),
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "substep_hz": 1000,
        "warmup_seconds": _warmup_seconds,
        "measured_seconds": _seconds,
        "vsync_mode": DisplayServer.window_get_vsync_mode(),
        "video_adapter": adapter,
        "rendering_method": RenderingServer.get_current_rendering_method(),
    }))
    output.close()
    runtime.queue_free()
    quit(0)


func _configure_effects(native: Object) -> bool:
    if _effects != "off" and _effects != "on":
        _fail("--effects must be off or on")
        return false
    var enabled := _effects == "on"
    if not native.call("set_a3_drag_model", enabled, 0.0001, 0.0001, 0.00012):
        _fail("cannot configure A3 drag")
        return false
    if not native.call("set_a4_ground_effect_model", enabled, 3.16e-10, 11.36859, 0.0231348, 0.0231348, 12000.0, 12000.0, 12000.0, 12000.0):
        _fail("cannot configure A4 ground effect")
        return false
    if not native.call("set_a6_propwash_model", enabled, 12.0, 2.0, 0.5):
        _fail("cannot configure A6 propwash")
        return false
    return true


func _parse_args() -> void:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        match args[index]:
            "--output":
                _output_path = args[index + 1]
            "--warmup-seconds":
                _warmup_seconds = args[index + 1].to_float()
            "--seconds":
                _seconds = args[index + 1].to_float()
            "--effects":
                _effects = args[index + 1]
            "--benchmark-mode":
                _benchmark_mode = args[index + 1]
            "--godot-version":
                _godot_version = args[index + 1]
            "--godot-sha256":
                _godot_sha256 = args[index + 1]
            "--godot-cpp-revision":
                _godot_cpp_revision = args[index + 1]
            "--gdextension-sha256":
                _gdextension_sha256 = args[index + 1]
            "--native-source-sha256":
                _native_source_sha256 = args[index + 1]
            "--require-adapter":
                _required_adapter = args[index + 1]


func _fail(message: String) -> void:
    push_error(message)
    quit(1)


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
