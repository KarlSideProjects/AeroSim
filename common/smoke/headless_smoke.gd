extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var output_path := _output_path()
    var requested_frames := _requested_frames()
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

    for _frame in range(requested_frames):
        await physics_frame

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
        "simulated_frames": requested_frames
    }))
    quit(0)

func _output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_smoke.json")

func _requested_frames() -> int:
    var frames := _int_arg("--frames", 3)
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        frames = ceili(seconds * float(Engine.physics_ticks_per_second))
    return maxi(frames, 1)

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
