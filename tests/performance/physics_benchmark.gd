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
    if runtime.screen != "controller_confirmation":
        _fail("benchmark must enter Xbox default profile confirmation before preflight")
        return
    runtime.accept_controller_confirmation()
    await process_frame
    if runtime.screen != "preflight" or runtime.session_gamepad_profile == null or runtime.takeoff_requested:
        _fail("benchmark must confirm the Xbox default profile before entering low-throttle preflight")
        return
    runtime.arm_and_takeoff()
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
        "active_effects": ["A3_drag", "A4_ground_effect"] if _effects == "on" else [],
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
