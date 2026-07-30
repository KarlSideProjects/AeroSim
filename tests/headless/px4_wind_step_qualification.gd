extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const TraceWriter = preload("res://common/diagnostics/px4_qualification_trace_writer.gd")
const QualificationSupport = preload("res://tests/headless/px4_qualification_support.gd")
const QualificationSpawnWorld := Vector3(-1.0, 0.0, 0.0)
const QualificationSecondarySpawnWorld := Vector3(-1.0, 0.0, 2.0)

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
    QualificationSupport.install(_smoke)
    _place_qualification_vehicles_in_clear_corridor()
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


func _place_qualification_vehicles_in_clear_corridor() -> void:
    # This headless qualification scene does not load a Free Flight map, so it
    # must explicitly use FlightRuntime's normal fallback spawn rather than
    # the authored smoke-scene origin, which is inside RuntimeWall. Drone1
    # starts on the negative-x side and the mission keeps moving farther away;
    # the parked Drone2 is kept clear of that flight path.
    if _smoke.drone_body == null or not _smoke.drone_body.has_method("apply_native_state"):
        push_error("PX4 wind qualification cannot place Drone1 in its clear corridor")
        quit(1)
        return
    _smoke.drone_body.reset_contact()
    _smoke.drone_body.apply_native_state(QualificationSpawnWorld, Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    _smoke.drone_body.freeze = false
    if _smoke.native != null and _smoke.native.has_method("reset_flight"):
        _smoke.native.call("reset_flight")
    if _smoke.secondary_drone_body != null and _smoke.secondary_drone_body.has_method("apply_native_state"):
        _smoke.secondary_drone_body.reset_contact()
        _smoke.secondary_drone_body.apply_native_state(QualificationSecondarySpawnWorld, Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
        _smoke.secondary_drone_body.freeze = true


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
    var airsim_snapshot: Dictionary = _smoke._airsim_state("Drone1")
    var airsim_state: Dictionary = airsim_snapshot.get("state", {})
    var truth_kinematics: Dictionary = airsim_state.get("kinematics_estimated", {})
    var truth_position: Dictionary = truth_kinematics.get("position", {})
    var truth_velocity: Dictionary = truth_kinematics.get("linear_velocity", {})
    var runtime := {
        "native_external_authority_state": _smoke._native_external_authority_state == true,
        "native_control_authority": native_authority,
        "bridge_authority_active": bridge.is_authority_active(),
        "bridge_state": String(bridge.state),
        "px4_takeoff_ground_release_pending": _smoke._px4_takeoff_ground_release_pending,
        "px4_launch_handoff_events": _smoke._px4_launch_handoff_events.duplicate(true),
        "last_collision_authority": _smoke.last_collision_authority,
        "px4_collision_input": _smoke._last_px4_collision_input,
    }
    var runtime_signature := JSON.stringify(runtime)
    if runtime_signature != _last_runtime_signature:
        _last_runtime_signature = runtime_signature
        var event := runtime.duplicate(true)
        event["time_seconds"] = Time.get_ticks_usec() / 1_000_000.0
        _runtime_authority_events.append(event)
    # This is trace-only truth used by the external mission gate. Keep it out
    # of runtime authority-event signatures so changing kinematics does not
    # turn diagnostics into an unbounded per-physics-frame log.
    runtime["truth_kinematics_ned"] = {
        "position_ned": [
            float(truth_position.get("x_val", NAN)),
            float(truth_position.get("y_val", NAN)),
            float(truth_position.get("z_val", NAN)),
        ],
        "velocity_ned_mps": [
            float(truth_velocity.get("x_val", NAN)),
            float(truth_velocity.get("y_val", NAN)),
            float(truth_velocity.get("z_val", NAN)),
        ],
    }
    var now_msec := Time.get_ticks_msec()
    if not force and _last_trace_write_msec >= 0 and now_msec - _last_trace_write_msec < 250:
        return
    _last_trace_write_msec = now_msec
    _last_trace_count = trace.size()
    _last_runtime_authority = native_authority
    var write_result: Dictionary = TraceWriter.replace_json(_trace_path, {
        "kind": "aerosim.px4_bridge_qualification_trace",
        "bridge_events": trace,
        "runtime": runtime,
        "runtime_authority_events": _runtime_authority_events,
    })
    if not bool(write_result.get("ok", false)):
        push_warning("PX4 qualification trace was not published: %s" % String(write_result.get("error", "unknown error")))
