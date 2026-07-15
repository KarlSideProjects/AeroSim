extends SceneTree

const Px4SitlBridge = preload("res://common/rpc/px4_sitl_bridge.gd")


func _init() -> void:
    var output_path := "build/px4_sitl_smoke.json"
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--output":
            output_path = args[index + 1]

    var bridge := Px4SitlBridge.new()
    var configure_result := bridge.configure({
        "VehicleType": "PX4Multirotor",
        "Transport": "Fake",
        "UseSerial": false,
        "LockStep": true,
        "HeartbeatTimeout": 1.0,
        "FailureTimeout": 3.0
    })
    var ok: bool = bool(configure_result.get("ok", false)) and bool(bridge.start().get("ok", false))
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    ok = ok and bridge.state == "connected"
    ok = ok and bridge.arm_disarm(true).ok
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.01)
    ok = ok and bridge.state == "armed"
    ok = ok and bridge.takeoff(Vector3(0.0, 0.0, -5.0)).ok
    ok = ok and bridge.move_to_position(Vector3(4.0, -2.0, -5.0)).ok
    ok = ok and bridge.hover().ok
    ok = ok and bridge.land().ok
    ok = ok and bridge.arm_disarm(false).ok
    ok = ok and bridge.mission_phase == "disarmed"

    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("PX4 SITL smoke could not write %s" % output_path)
        quit(1)
        return
    file.store_string(JSON.stringify({
        "completed": ok,
        "state": bridge.state,
        "mission_phase": bridge.mission_phase,
        "diagnostics": bridge.diagnostics()
    }))
    file.close()
    quit(0 if ok else 1)
