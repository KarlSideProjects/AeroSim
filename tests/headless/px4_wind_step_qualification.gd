extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")

var _ready_path := ""
var _stop_path := ""
var _trace_path := ""
var _smoke: Node
var _last_trace_count := -1
var _last_runtime_authority := ""
var _last_runtime_signature := ""
var _runtime_authority_events: Array[Dictionary] = []
var _last_trace_write_msec := -1


func _init() -> void:
    var args := OS.get_cmdline_user_args()
    _ready_path = _argument(args, "--gsp-ready-file")
    _stop_path = _argument(args, "--airsim-stop-file")
    _trace_path = _argument(args, "--px4-trace-file")
    if _ready_path.is_empty() or _stop_path.is_empty() or _trace_path.is_empty():
        push_error("PX4 wind qualification requires --gsp-ready-file, --airsim-stop-file, and --px4-trace-file")
        quit(2)
        return
    call_deferred("_start")


func _start() -> void:
    _smoke = SmokeScene.instantiate()
    get_root().add_child(_smoke)
    var bridge = _smoke.px4_sitl_bridge
    if bridge == null or not bridge.has_method("set_qualification_trace_enabled"):
        push_error("PX4 wind qualification cannot enable bridge diagnostics")
        quit(1)
        return
    bridge.set_qualification_trace_enabled(true)
    _write_trace()
    await process_frame
    var launcher := _smoke.get_node_or_null("GspLauncher")
    if launcher == null or not launcher.has_method("launch"):
        push_error("PX4 wind qualification cannot find GspLauncher")
        quit(1)
        return
    var launched: Dictionary = launcher.call("launch", {"open": false})
    if not bool(launched.get("ok", false)):
        push_error("PX4 wind qualification could not start GSP: %s" % String(launched.get("error", "unknown error")))
        quit(1)
        return
    var ready := FileAccess.open(_ready_path, FileAccess.WRITE)
    if ready == null:
        push_error("PX4 wind qualification could not publish GSP readiness")
        quit(1)
        return
    ready.store_string(JSON.stringify({
        "port": int(launched.get("gsp_port", 0)),
        "token": String(launcher._server.get_token()),
        "gsp_running": bool(launched.get("gsp_running", false)),
    }))
    ready.flush()
    ready.close()


func _process(_delta: float) -> bool:
    _write_trace()
    if not _stop_path.is_empty() and FileAccess.file_exists(_stop_path):
        _write_trace(true)
        if _smoke != null:
            _smoke.queue_free()
        quit(0)
    return false


func _argument(args: Array[String], name: String) -> String:
    var index := args.find(name)
    return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""


func _write_trace(force: bool = false) -> void:
    if _trace_path.is_empty() or _smoke == null:
        return
    var bridge = _smoke.px4_sitl_bridge
    if bridge == null or not bridge.has_method("qualification_trace"):
        return
    var trace: Array = bridge.qualification_trace()
    var native_snapshot: Dictionary = _smoke.native.call("telemetry_snapshot") if _smoke.native != null and _smoke.native.has_method("telemetry_snapshot") else {}
    var native_authority := String(native_snapshot.get("control_authority", "unavailable"))
    var runtime := {
        "native_external_authority_state": _smoke._native_external_authority_state == true,
        "native_control_authority": native_authority,
        "bridge_authority_active": bridge.is_authority_active(),
        "bridge_state": String(bridge.state),
        "px4_takeoff_ground_release_pending": _smoke._px4_takeoff_ground_release_pending,
        "last_collision_authority": _smoke.last_collision_authority,
    }
    var runtime_signature := JSON.stringify(runtime)
    if runtime_signature != _last_runtime_signature:
        _last_runtime_signature = runtime_signature
        var event := runtime.duplicate(true)
        event["time_seconds"] = Time.get_ticks_usec() / 1_000_000.0
        _runtime_authority_events.append(event)
    var now_msec := Time.get_ticks_msec()
    if not force and _last_trace_write_msec >= 0 and now_msec - _last_trace_write_msec < 250:
        return
    _last_trace_write_msec = now_msec
    _last_trace_count = trace.size()
    _last_runtime_authority = native_authority
    var output := FileAccess.open(_trace_path, FileAccess.WRITE)
    if output == null:
        return
    output.store_string(JSON.stringify({
        "kind": "aerosim.px4_bridge_qualification_trace",
        "bridge_events": trace,
        "runtime": runtime,
        "runtime_authority_events": _runtime_authority_events,
    }))
    output.flush()
    output.close()
