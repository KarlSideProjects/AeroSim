extends GutTest

const Px4SitlBridgeScript = preload("res://common/rpc/px4_sitl_bridge.gd")

var authority_events: Array[bool] = []


func before_each() -> void:
    authority_events.clear()


func test_fake_transport_reaches_connected_armed_and_fails_after_stale() -> void:
    var bridge := _new_fake_bridge(0.1)

    assert_true(bridge.start().ok)
    assert_eq(bridge.state, "starting")

    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    assert_eq(bridge.state, "connected")

    bridge.inject_heartbeat(true)
    bridge.poll(0.01)
    assert_eq(bridge.state, "armed")
    assert_true(authority_events.back())

    bridge.poll(0.2)
    assert_eq(bridge.state, "stale")
    assert_false(authority_events.back())

    bridge.poll(0.31)
    assert_eq(bridge.state, "failed")
    assert_false(bridge.diagnostics().message.is_empty())


func test_fake_mission_preserves_ned_frd_and_finishes_disarmed() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)

    assert_true(bridge.arm_disarm(true).ok)
    bridge.inject_heartbeat(true)
    bridge.poll(0.01)
    assert_eq(bridge.state, "armed")

    assert_true(bridge.takeoff(Vector3(0.0, 0.0, -5.0)).ok)
    assert_eq(bridge.mission_phase, "takeoff")
    assert_true(bridge.move_to_position(Vector3(4.0, -2.0, -5.0)).ok)
    assert_eq(bridge.last_setpoint.position_ned, Vector3(4.0, -2.0, -5.0))
    assert_true(bridge.hover().ok)
    assert_eq(bridge.mission_phase, "hover")
    assert_true(bridge.land().ok)
    assert_eq(bridge.mission_phase, "land")
    assert_true(bridge.arm_disarm(false).ok)
    assert_eq(bridge.mission_phase, "disarmed")
    assert_false(bridge.is_authority_active())


func test_fake_setpoint_keeps_body_rates_in_frd() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)

    var result := bridge.setpoint_ned_frd(Vector3(1.0, 2.0, -3.0), Vector3(0.1, -0.2, 0.3))
    assert_true(result.ok)
    assert_eq(bridge.last_setpoint.position_ned, Vector3(1.0, 2.0, -3.0))
    assert_eq(bridge.last_setpoint.body_rates_frd, Vector3(0.1, -0.2, 0.3))


func _new_fake_bridge(heartbeat_timeout: float) -> Px4SitlBridge:
    var bridge := Px4SitlBridgeScript.new()
    bridge.configure({
        "VehicleType": "PX4Multirotor",
        "Transport": "Fake",
        "HeartbeatTimeout": heartbeat_timeout,
        "FailureTimeout": heartbeat_timeout * 3.0,
        "UseSerial": false,
        "LockStep": true
    }, Callable(self, "_on_authority_changed"))
    return bridge


func _on_authority_changed(active: bool) -> void:
    authority_events.append(active)
