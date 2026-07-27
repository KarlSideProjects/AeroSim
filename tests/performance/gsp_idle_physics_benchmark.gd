extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")

var _output_path := "build/gsp-idle-benchmark.raw.json"
var _mode := "disabled"
var _warmup_seconds := 10.0
var _seconds := 60.0
var _commit_sha := ""
var _native: Object
var _runtime: Node
var _server: GspServer
var _client := WebSocketPeer.new()
var _samples_usec: Array[int] = []
var _physics_tick := 0


func _init() -> void:
    _parse_args()
    call_deferred("_run")


func _run() -> void:
    if _mode not in ["disabled", "authenticated-idle"] or _warmup_seconds != 10.0 or _seconds != 60.0 or _commit_sha.length() != 40:
        _fail("paired benchmark requires disabled/authenticated-idle, exact 10+60 seconds, and commit provenance")
        return
    _runtime = SmokeScene.instantiate()
    root.add_child(_runtime)
    await process_frame
    _native = _runtime.native
    if _native == null:
        _fail("SmokeScene did not initialize AeroSimNative")
        return
    if _mode == "authenticated-idle" and not await _connect_authenticated_idle():
        _fail("authenticated idle GSP client could not connect")
        return
    var warmup_frames := int(_warmup_seconds * Engine.physics_ticks_per_second)
    for _frame in warmup_frames:
        await physics_frame
        _step_native()
        _pump_client()
    _samples_usec.clear()
    var measurement_frames := int(_seconds * Engine.physics_ticks_per_second)
    for _frame in measurement_frames:
        await physics_frame
        var started_usec := Time.get_ticks_usec()
        _step_native()
        _samples_usec.append(Time.get_ticks_usec() - started_usec)
        _pump_client()
    _write_output()
    if _server != null:
        _server.stop()
    quit(0)


func _connect_authenticated_idle() -> bool:
    _server = GspServer.new()
    root.add_child(_server)
    _server.set_identity_provider(Callable(_runtime, "gsp_identity_snapshot"))
    _server.set_telemetry_provider(Callable(_runtime, "gsp_telemetry_snapshot"))
    var started := _server.start()
    if not bool(started.get("ok", false)):
        return false
    _client.handshake_headers = PackedStringArray(["Origin: null"])
    _client.connect_to_url("ws://127.0.0.1:%d" % int(started.get("port", 0)))
    for _attempt in 240:
        _client.poll()
        if _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
            _client.send_text(JSON.stringify({"v": 2, "t": "auth", "seq": 0, "d": {"token": started.token}}))
            break
        await process_frame
    if _client.get_ready_state() != WebSocketPeer.STATE_OPEN:
        return false
    for _attempt in 240:
        _server.poll()
        _client.poll()
        while _client.get_available_packet_count() > 0:
            var packet := _client.get_packet()
            if not _client.was_string_packet():
                continue
            var message = JSON.parse_string(packet.get_string_from_utf8())
            if typeof(message) != TYPE_DICTIONARY:
                continue
            if String(message.get("t", "")) == "hello":
                _client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 1, "d": {"hz": 30, "extra": []}}))
                return true
        await process_frame
    return false


func _pump_client() -> void:
    if _client.get_ready_state() != WebSocketPeer.STATE_OPEN:
        return
    _client.poll()
    while _client.get_available_packet_count() > 0:
        _client.get_packet()


func _step_native() -> void:
    _physics_tick += 1
    _native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    _native.call("step_angle_mode", 240, 1000, 0.75, 0.0, 0.0, 0.0)


func _write_output() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output_path.get_base_dir()))
    var file := FileAccess.open(_output_path, FileAccess.WRITE)
    if file == null:
        _fail("could not write paired benchmark artifact")
        return
    file.store_string(JSON.stringify({
        "mode": _mode,
        "commit_sha": _commit_sha,
        "warmup_seconds": _warmup_seconds,
        "measured_seconds": _seconds,
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "sample_count": _samples_usec.size(),
        "samples_usec": _samples_usec,
        "sampling_source": "AeroSimNative.step_angle_mode inside a real Godot physics-frame workload",
        "authenticated_idle": _mode == "authenticated-idle",
    }))
    file.close()


func _parse_args() -> void:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        match args[index]:
            "--output":
                _output_path = args[index + 1]
            "--mode":
                _mode = args[index + 1]
            "--warmup-seconds":
                _warmup_seconds = args[index + 1].to_float()
            "--seconds":
                _seconds = args[index + 1].to_float()
            "--commit-sha":
                _commit_sha = args[index + 1]


func _fail(message: String) -> void:
    push_error(message)
    quit(1)
