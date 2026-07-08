extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var output_path := _output_path()
    var csv_output_path := _csv_output_path()
    var requested_frames := _requested_frames()
    var requested_seconds := _requested_seconds(requested_frames)
    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        quit(1)
        return

    var probe_value: int = native.call("probe_value")

    if probe_value != 47:
        push_error("AeroSimNative.probe_value returned %d" % probe_value)
        quit(1)
        return

    var trajectory := PackedFloat64Array()
    native.call("reset_simulation")
    for _frame in range(requested_frames):
        await physics_frame
        var row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.0)
        trajectory.append_array(row)

    var mobile_trajectory: PackedFloat64Array = native.call("simulate_trajectory", 1.0, 120, 500, 0.0)
    var stride: int = native.call("trajectory_stride")

    if trajectory.is_empty() or mobile_trajectory.is_empty() or stride != 12:
        push_error("AeroSimNative.simulate_trajectory returned invalid data")
        quit(1)
        return

    if not _write_trajectory_csv(csv_output_path, trajectory, stride):
        quit(1)
        return

    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write smoke output: %s" % output_path)
        quit(1)
        return

    file.store_string(JSON.stringify({
        "schema_version": 1,
        "native_probe": probe_value,
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "requested_seconds": float(requested_frames) / float(Engine.physics_ticks_per_second),
        "simulated_frames": requested_frames,
        "trajectory_csv": csv_output_path,
        "trajectory_stride": stride,
        "trajectory_samples": int(trajectory.size() / stride),
        "desktop_substep_hz": 1000,
        "desktop_substeps": int(trajectory[trajectory.size() - 1]),
        "mobile_substep_hz": 500,
        "mobile_substeps_1s": int(mobile_trajectory[mobile_trajectory.size() - 1])
    }))
    quit(0)

func _output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_smoke.json")

func _csv_output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--csv-output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_trajectory.csv")

func _requested_frames() -> int:
    var frames := _int_arg("--frames", 3)
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        frames = ceili(seconds * float(Engine.physics_ticks_per_second))
    return maxi(frames, 1)

func _requested_seconds(requested_frames: int) -> float:
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        return seconds
    return float(requested_frames) / float(Engine.physics_ticks_per_second)

func _write_trajectory_csv(path: String, trajectory: PackedFloat64Array, stride: int) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write trajectory CSV: %s" % path)
        return false

    file.store_line("time_s,position_x_m,position_y_m,position_z_m,orientation_x,orientation_y,orientation_z,orientation_w,velocity_x_mps,velocity_y_mps,velocity_z_mps,substeps")
    for row in range(int(trajectory.size() / stride)):
        var offset := row * stride
        var values: Array[String] = []
        for column in range(stride):
            values.append("%.10f" % trajectory[offset + column])
        file.store_line(",".join(values))
    return true

func _int_arg(name: String, default_value: int) -> int:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_int()
    return default_value

func _float_arg(name: String, default_value: float) -> float:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_float()
    return default_value

func _project_path(path: String) -> String:
    if path.is_absolute_path():
        return path
    return ProjectSettings.globalize_path("res://").path_join(path)
