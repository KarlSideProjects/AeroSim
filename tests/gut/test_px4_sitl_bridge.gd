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
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.01)
    assert_eq(bridge.state, "armed")
    assert_true(authority_events.back())

    bridge.poll(0.2)
    assert_eq(bridge.state, "stale")
    assert_false(authority_events.back())

    bridge.poll(0.31)
    assert_eq(bridge.state, "failed")
    assert_false(bridge.diagnostics().message.is_empty())


func test_fake_armed_transport_reconnects_before_failure_timeout() -> void:
    var bridge := _new_fake_bridge(0.1)

    assert_true(bridge.start().ok)
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    bridge.arm_disarm(true)
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.01)
    assert_eq(bridge.state, "armed")

    bridge.poll(0.2)
    assert_eq(bridge.state, "stale")
    assert_false(bridge.is_authority_active())

    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.21)

    assert_eq(bridge.state, "armed")
    assert_true(bridge.is_authority_active())
    assert_eq(bridge.diagnostics().last_heartbeat_time, 0.21)


func test_fake_startup_fails_without_heartbeat() -> void:
    var bridge := _new_fake_bridge(0.1)

    assert_true(bridge.start().ok)
    bridge.poll(0.0)
    bridge.poll(0.31)

    assert_eq(bridge.state, "failed")
    assert_false(bridge.is_authority_active())


func test_fake_armed_authority_expires_when_actuators_stop() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    assert_true(bridge.arm_disarm(true).ok)
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.25, 0.5, 0.75, 1.0])
    bridge.poll(0.01)

    assert_eq(bridge.state, "armed")
    assert_true(bridge.is_authority_active())
    assert_eq(bridge.actuator_outputs().size(), 4)

    bridge.poll(0.12)
    assert_eq(bridge.state, "stale")
    assert_false(bridge.is_authority_active())
    assert_eq(bridge.actuator_outputs().size(), 0)


func test_fake_armed_heartbeat_allows_takeoff_before_first_actuator() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    assert_true(bridge.arm_disarm(true).ok)

    bridge.inject_heartbeat(true)
    bridge.poll(0.01)
    assert_eq(bridge.state, "armed")
    assert_true(bridge.is_authority_active())
    assert_true(bridge.takeoff(Vector3(0.0, 0.0, -2.0)).ok)

    bridge.poll(0.2)
    assert_eq(bridge.state, "armed")
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.21)
    bridge.poll(0.32)
    assert_eq(bridge.state, "stale")


func test_fake_heartbeat_does_not_restore_stale_authority_without_actuators() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    bridge.arm_disarm(true)
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.25, 0.5, 0.75, 1.0])
    bridge.poll(0.01)
    assert_eq(bridge.state, "armed")

    bridge.poll(0.12)
    assert_eq(bridge.state, "stale")
    bridge.inject_heartbeat(true)
    bridge.poll(0.13)
    assert_eq(bridge.state, "stale")
    assert_false(bridge.is_authority_active())

    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.14)
    assert_eq(bridge.state, "armed")
    assert_true(bridge.is_authority_active())


func test_fake_mission_preserves_ned_frd_and_finishes_disarmed() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)

    assert_true(bridge.arm_disarm(true).ok)
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
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
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.01)

    var result := bridge.setpoint_ned_frd(Vector3(1.0, 2.0, -3.0), Vector3(0.1, -0.2, 0.3))
    assert_true(result.ok)
    assert_eq(bridge.last_setpoint.position_ned, Vector3(1.0, 2.0, -3.0))
    assert_eq(bridge.last_setpoint.body_rates_frd, Vector3(0.1, -0.2, 0.3))


func test_real_parser_accepts_px4_mavlink_v2_heartbeat() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    var frame := PackedByteArray([
        0xFD, 0x09, 0x00, 0x00, 0xE8, 0x01, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x04, 0x03, 0x02, 0x0C, 0x3D, 0x08, 0x03,
        0x0A, 0xC8
    ])

    bridge._consume_mavlink(frame, 2.0, PackedByteArray())

    assert_eq(bridge.state, "connected")
    assert_eq(bridge.diagnostics().last_heartbeat_time, 2.0)


func test_real_parser_keeps_armed_hil_actuator_controls() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge.inject_heartbeat(true)
    bridge.poll(0.0)

    var payload := bridge._u64_bytes(1000)
    for _index in 8:
        payload.append(0)
    for value in [0.25, 0.5, 0.75, 1.0]:
        payload.append_array(bridge._float_bytes(value))
    for _index in 12:
        payload.append_array(bridge._float_bytes(0.0))
    payload.append(0x81)
    var frame := PackedByteArray([0xFE, payload.size(), 0, 1, 1, 93])
    frame.append_array(payload)
    var crc := bridge._mavlink_crc(frame.slice(1), 47)
    frame.append(crc & 0xFF)
    frame.append((crc >> 8) & 0xFF)

    bridge._consume_mavlink(frame, 0.01, PackedByteArray())

    assert_eq(bridge.state, "armed")
    assert_eq(bridge.actuator_outputs(), PackedFloat32Array([0.25, 0.5, 0.75, 1.0]))


func test_real_parser_exposes_only_crc_valid_px4_observability() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    var frames := [
        _mavlink_frame(bridge, 30, _floats([12.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6])),
        _mavlink_frame(bridge, 32, _floats([13.0, 1.0, 2.0, -3.0, 4.0, 5.0, -6.0])),
        _mavlink_frame(bridge, 83, _floats([14.0, 1.0, 0.0, 0.0, 0.0, 0.1, 0.2, 0.3, 0.7]) + PackedByteArray([0])),
        _mavlink_frame(bridge, 85, _floats([15.0, 7.0, 8.0, -9.0, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.4, 0.5]) + bridge._u16_bytes(0) + PackedByteArray([1])),
        _mavlink_frame(bridge, 231, bridge._u64_bytes(16_000) + _floats([2.0, 3.0, 4.0, 0.1, 0.2, 100.0, 0.3, 0.4])),
    ]
    for frame in frames:
        bridge._consume_mavlink(frame, 2.0, PackedByteArray())

    var observed := bridge.px4_observability(2.25)
    assert_eq(observed.attitude.source, "px4_mavlink")
    assert_eq(observed.local_position_ned.sample.position_ned, Vector3(1.0, 2.0, -3.0))
    assert_almost_eq(observed.attitude_target.sample.thrust, 0.7, 0.00001)
    assert_eq(observed.position_target_local_ned.sample.position_ned, Vector3(7.0, 8.0, -9.0))
    assert_eq(observed.wind_cov.sample.wind_ned_mps, Vector3(2.0, 3.0, 4.0))
    assert_eq(observed.attitude.age_seconds, 0.25)
    assert_false(observed.has("body_torque_nm"))

    var invalid := _mavlink_frame(bridge, 30, _floats([99.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0]))
    invalid[10] ^= 0x01
    bridge._consume_mavlink(invalid, 3.0, PackedByteArray())
    assert_almost_eq(bridge.px4_observability(3.0).attitude.sample.roll_rad, 0.1, 0.00001)


func test_px4_actuator_commands_are_m1_to_m4_and_fail_closed_when_stale() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge.start()
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    bridge.arm_disarm(true)
    bridge.inject_heartbeat(true)
    bridge.poll(0.01)
    var payload := bridge._u64_bytes(1000)
    for _index in 8:
        payload.append(0)
    for value in [0.25, 0.5, 0.75, 1.0]:
        payload.append_array(bridge._float_bytes(value))
    for _index in 12:
        payload.append_array(bridge._float_bytes(0.0))
    payload.append(0x81)
    bridge._consume_mavlink(_mavlink_frame(bridge, 93, payload), 0.01, PackedByteArray())

    assert_eq(bridge.px4_observability(0.02).hil_actuator_controls.sample.command_normalized, {"m1": 0.25, "m2": 0.5, "m3": 0.75, "m4": 1.0})
    bridge.poll(0.12)
    assert_eq(bridge.actuator_outputs().size(), 0)
    assert_true(bridge.px4_observability(0.12).hil_actuator_controls.stale)


func _floats(values: Array) -> PackedByteArray:
    var bytes := PackedByteArray()
    for value in values:
        bytes.append_array(Px4SitlBridgeScript.new()._float_bytes(float(value)))
    return bytes


func _mavlink_frame(bridge: Px4SitlBridge, message_id: int, payload: PackedByteArray) -> PackedByteArray:
    var frame := PackedByteArray([0xFE, payload.size(), 0, 1, 1, message_id])
    frame.append_array(payload)
    var crc := bridge._mavlink_crc(frame.slice(1), bridge._crc_extra(message_id))
    frame.append(crc & 0xFF)
    frame.append((crc >> 8) & 0xFF)
    return frame


func _new_fake_bridge(heartbeat_timeout: float, actuator_timeout: float = -1.0) -> Px4SitlBridge:
    var bridge := Px4SitlBridgeScript.new()
    if actuator_timeout < 0.0:
        actuator_timeout = heartbeat_timeout
    bridge.configure({
        "VehicleType": "PX4Multirotor",
        "Transport": "Fake",
        "HeartbeatTimeout": heartbeat_timeout,
        "FailureTimeout": heartbeat_timeout * 3.0,
        "ActuatorTimeout": actuator_timeout,
        "UseSerial": false,
        "LockStep": true
    }, Callable(self, "_on_authority_changed"))
    return bridge


func _on_authority_changed(active: bool) -> void:
    authority_events.append(active)
