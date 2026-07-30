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


func test_hil_sensor_measurements_require_actual_mag_and_baro_samples() -> void:
    var bridge := _new_fake_bridge(1.0)
    var snapshot := {
        "kinematics_estimated": {"linear_velocity": {"x_val": 1.0, "y_val": -2.0, "z_val": 3.0}},
        "imu_sample": {
            "accel": {"x_val": 0.1, "y_val": 0.2, "z_val": -9.7},
            "gyro": {"x_val": 0.01, "y_val": 0.02, "z_val": 0.03},
        },
        "magnetometer": {"magnetic_field_body": {"x_val": 0.22, "y_val": 0.01, "z_val": 0.43}, "time_stamp": 20_000_000},
        "barometer": {"altitude_m": 123.0, "pressure_hpa": 998.5, "temperature_c": 24.9, "time_stamp": 20_000_000},
    }
    var measurements := bridge.hil_sensor_measurements(snapshot)
    assert_true(measurements.ok)
    assert_almost_eq(measurements.magnetic_field_gauss.y, 0.01, 0.000001)
    assert_almost_eq(measurements.absolute_pressure_hpa, 998.5, 0.000001)

    snapshot.erase("magnetometer")
    assert_false(bridge.hil_sensor_measurements(snapshot).ok, "The HIL bridge must fail closed instead of inventing a magnetic field.")


func test_hil_sensor_masks_only_declare_resampled_mag_and_baro_groups() -> void:
    var bridge := _new_fake_bridge(1.0)
    var snapshot := {
        "magnetometer": {"time_stamp": 20_000_000},
        "barometer": {"time_stamp": 20_000_000},
    }

    assert_eq(bridge.hil_sensor_fields_updated(snapshot), 1 << 31)
    assert_eq(bridge.hil_sensor_fields_updated(snapshot), 0x1BFF)
    assert_eq(bridge.hil_sensor_fields_updated(snapshot), 0x003F)
    snapshot.magnetometer.time_stamp = 40_000_000
    snapshot.barometer.time_stamp = 40_000_000
    assert_eq(bridge.hil_sensor_fields_updated(snapshot), 0x1BFF)


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


func test_offboard_target_waits_for_kinematics_then_fails_closed_after_publisher_start() -> void:
    var bridge := _new_fake_bridge(2.0)
    bridge._config.Transport = "Real"
    bridge.set_qualification_trace_enabled(true)
    bridge.state = "armed"
    bridge._authority_active = true
    bridge._last_heartbeat_time = 0.0
    bridge._estimator_ready_report_count = 2
    bridge._last_estimator_ready_report_time = -1.0
    assert_true(bridge.setpoint_ned_frd(Vector3(1.0, 2.0, -3.0), Vector3.ZERO).ok)
    assert_false(_qualification_trace_entry(bridge.qualification_trace(), "publisher_target_accepted").is_empty())

    bridge.poll(0.0)
    assert_false(_qualification_trace_entry(bridge.qualification_trace(), "publisher_waiting_kinematics").is_empty())
    assert_true(bridge._offboard_target_active)
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "outgoing_position_setpoint").size(), 0)

    bridge._consume_mavlink(_mavlink_frame(bridge, 30, _floats([0.01, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6])), 0.01, PackedByteArray())
    bridge._consume_mavlink(_mavlink_frame(bridge, 32, _floats([0.01, 1.0, 2.0, -3.0, 4.0, 5.0, -6.0])), 0.01, PackedByteArray())
    bridge.poll(0.01)
    assert_false(_qualification_trace_entry(bridge.qualification_trace(), "publisher_started").is_empty())
    assert_false(_qualification_trace_entry(bridge.qualification_trace(), "publisher_first_send").is_empty())
    bridge.poll(0.5)
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "outgoing_position_setpoint").size(), 2)
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "outgoing_command_long").size(), 0)
    bridge.poll(1.02)
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "outgoing_command_long").back().command, 176)

    var attitude_entry: Dictionary = bridge._px4_messages.attitude
    attitude_entry.received_at_seconds = -1.0
    bridge._px4_messages.attitude = attitude_entry
    bridge.poll(1.2)
    assert_eq(_qualification_trace_entry(bridge.qualification_trace(), "publisher_cleared").reason, "kinematics_lost_after_publisher_start")
    assert_false(bridge._offboard_target_active)
    var sent_before_clear := _qualification_trace_entries(bridge.qualification_trace(), "outgoing_position_setpoint").size()
    bridge.poll(1.3)
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "outgoing_position_setpoint").size(), sent_before_clear)


func test_real_lockstep_actuator_freshness_uses_hil_simulation_time_not_wall_clock() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge._config.Transport = "Real"
    bridge.state = "armed"
    bridge._armed_since = 0.0
    bridge._last_heartbeat_time = 0.0
    bridge._last_actuator_time = 0.01
    bridge._last_actuator_simulation_time = 40.0
    bridge._last_actuator_time_usec = 40_000_000
    bridge._last_sensor_time = 40.05

    assert_almost_eq(bridge._actuator_freshness_age_seconds(999.0), 0.05, 0.000001)
    bridge.poll(999.0)
    assert_eq(bridge.state, "armed", "A wall-clock stall must not trip a LockStep controller with a fresh HIL timestamp.")

    bridge._last_sensor_time = 40.11
    bridge.poll(999.0)
    assert_eq(bridge.state, "stale", "Advancing HIL simulation time beyond ActuatorTimeout must fail closed.")


func test_real_lockstep_canonicalizes_fractional_seconds_to_hil_microseconds() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge._config.Transport = "Real"
    bridge._last_actuator_simulation_time = 8.716667
    bridge._last_actuator_time_usec = 8_716_667
    bridge._last_sensor_time = 8.71666666666667

    assert_almost_eq(bridge._actuator_freshness_age_seconds(999.0), 0.0, 0.000001)


func test_lockstep_bootstrap_without_a_hil_actuator_timestamp_keeps_wall_clock_timeout() -> void:
    var bridge := _new_fake_bridge(1.0, 0.1)
    bridge._config.Transport = "Real"
    bridge.state = "armed"
    bridge._armed_since = 0.0
    bridge._last_heartbeat_time = 0.0
    bridge._last_actuator_time = 0.01

    bridge.poll(0.12)
    assert_eq(bridge.state, "stale", "Bootstrap must not silently use a missing HIL source timestamp as fresh control output.")


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
    assert_eq(bridge.actuator_outputs(), PackedFloat32Array([1.0, 0.25, 0.5, 0.75]))
    assert_almost_eq(bridge.diagnostics().last_actuator_simulation_time, 0.001, 0.000001)
    assert_eq(bridge.diagnostics().last_actuator_time_usec, 1000)


func test_qualification_trace_records_incoming_mode_armed_and_authority_transition() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.set_qualification_trace_enabled(true)
    bridge.start()
    bridge.poll(0.0)
    var heartbeat_payload := PackedByteArray([0, 0, 0, 0, 6, 8, 0x80, 3, 3])

    bridge._consume_mavlink(_mavlink_frame(bridge, 0, heartbeat_payload), 0.01, PackedByteArray())

    var trace: Array = bridge.qualification_trace()
    var heartbeat := _qualification_trace_entry(trace, "heartbeat")
    var authority_transition := _qualification_trace_entry(trace, "authority_transition")
    assert_eq(heartbeat.base_mode, 0x80)
    assert_true(bool(heartbeat.armed))
    assert_true(bool(heartbeat.bootstrapped))
    assert_false(bool(heartbeat.failsafe))
    assert_true(bool(authority_transition.active))
    assert_true(bool(authority_transition.callback_fired))
    var hil_payload := bridge._u64_bytes(1000) + bridge._u64_bytes(1)
    for value in [0.25, 0.5, 0.75, 1.0]:
        hil_payload.append_array(bridge._float_bytes(value))
    for _index in 12:
        hil_payload.append_array(bridge._float_bytes(0.0))
    hil_payload.append(0x81)
    bridge._consume_mavlink(_mavlink_frame(bridge, 93, hil_payload), 0.02, PackedByteArray())

    var actuator := _qualification_trace_entry(bridge.qualification_trace(), "hil_actuator_controls")
    assert_eq(actuator.flags, 1)
    assert_eq(actuator.time_usec, 1000)
    assert_almost_eq(actuator.simulation_time_seconds, 0.001, 0.000001)
    assert_eq(actuator.raw_outputs, [0.25, 0.5, 0.75, 1.0])
    assert_eq(actuator.outputs, [1.0, 0.25, 0.5, 0.75])
    assert_true(bool(actuator.mapping_verified))


func test_nav_takeoff_uses_current_global_position_and_absolute_altitude() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.set_qualification_trace_enabled(true)

    bridge._send_command_long(22, 0.0, 5.0)

    var command := _qualification_trace_entry(bridge.qualification_trace(), "outgoing_command_long")
    var parameters: Array = command.parameters
    assert_eq(command.command, 22)
    assert_true(is_nan(float(parameters[4])))
    assert_true(is_nan(float(parameters[5])))
    assert_eq(float(parameters[6]), 5.0)


func test_hil_gps_payload_matches_the_mavlink_wire_layout() -> void:
    var bridge := _new_fake_bridge(1.0)

    var payload: PackedByteArray = bridge._hil_gps_payload(1_234_567, 47.641468, -122.140165, 12.5, Vector3(1.25, -2.5, 0.75))

    assert_eq(payload.size(), 39)
    assert_eq(_u64_at(payload, 0), 1_234_567)
    assert_eq(_i32_at(payload, 8), 476_414_680)
    assert_eq(_i32_at(payload, 12), -1_221_401_650)
    assert_eq(_i32_at(payload, 16), 12_500)
    assert_eq(int(payload[34]), 3)


func test_estimator_status_requires_two_fresh_valid_reports_before_readiness() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()

    bridge._consume_mavlink(_mavlink_frame(bridge, 230, _estimator_status_payload(63)), 1.0, PackedByteArray())
    assert_false(bridge.estimator_ready(1.0))

    bridge._consume_mavlink(_mavlink_frame(bridge, 230, _estimator_status_payload(63)), 1.2, PackedByteArray())
    assert_true(bridge.estimator_ready(1.2))
    assert_eq(bridge.px4_observability(1.2).estimator_status.sample.flags, 63)
    assert_false(bridge.estimator_ready(2.21))


func test_bridge_diagnostics_observability_is_source_labeled_and_not_mavlink() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge.state = "armed"
    bridge.mission_phase = "takeoff"
    bridge._authority_active = true
    bridge._last_command_result = 0

    var diagnostics: Dictionary = bridge.px4_observability(1.0).bridge_diagnostics
    assert_eq(diagnostics.source, "px4_bridge")
    assert_eq(diagnostics.sample.state, "armed")
    assert_true(bool(diagnostics.sample.authority_active))
    assert_eq(diagnostics.sample.mission_phase, "takeoff")
    assert_eq(diagnostics.sample.last_command_result, 0)


func test_estimator_status_rejects_incomplete_flags_and_real_bootstrap_fails_closed() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.set_qualification_trace_enabled(true)
    bridge.start()
    bridge._config.Transport = "Real"
    bridge.state = "connected"
    bridge._start_time = 0.0
    bridge._last_heartbeat_time = 7.9

    bridge._consume_mavlink(_mavlink_frame(bridge, 230, _estimator_status_payload(164)), 7.0, PackedByteArray())
    bridge._consume_mavlink(_mavlink_frame(bridge, 230, _estimator_status_payload(164)), 7.5, PackedByteArray())
    assert_false(bridge.estimator_ready(7.5))

    assert_true(bridge.arm_disarm(true).ok)
    bridge.poll(8.0)

    assert_eq(bridge.state, "failed")
    assert_string_contains(bridge.diagnostics().message, "estimator readiness")
    assert_eq(_qualification_trace_entry(bridge.qualification_trace(), "outgoing_command_long"), {})


func test_real_bootstrap_arms_after_two_fresh_valid_estimator_reports() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.set_qualification_trace_enabled(true)
    bridge.start()
    bridge._config.Transport = "Real"
    bridge.state = "connected"
    bridge._start_time = 0.0
    bridge._last_heartbeat_time = 7.9

    bridge._consume_mavlink(_mavlink_frame(bridge, 230, _estimator_status_payload(63)), 7.0, PackedByteArray())
    bridge._consume_mavlink(_mavlink_frame(bridge, 230, _estimator_status_payload(63)), 7.5, PackedByteArray())
    assert_true(bridge.arm_disarm(true).ok)
    bridge.poll(8.0)

    assert_eq(bridge.state, "connected")
    assert_eq(_qualification_trace_entry(bridge.qualification_trace(), "outgoing_command_long").command, 400)


func test_real_parser_exposes_only_crc_valid_px4_observability() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    var frames := [
        _mavlink_frame(bridge, 30, _floats([12.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6])),
        _mavlink_frame(bridge, 32, _floats([13.0, 1.0, 2.0, -3.0, 4.0, 5.0, -6.0])),
        _mavlink_frame(bridge, 83, _floats([14.0, 1.0, 0.2, 0.3, 0.4, 0.1, 0.2, 0.3, 0.7]) + PackedByteArray([0])),
        _mavlink_frame(bridge, 85, _floats([15.0, 7.0, 8.0, -9.0, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.4, 0.5]) + bridge._u16_bytes(0) + PackedByteArray([1])),
        _mavlink_frame(bridge, 231, bridge._u64_bytes(16_000) + _floats([2.0, 3.0, 4.0, 0.1, 0.2, 100.0, 0.3, 0.4])),
    ]
    for frame in frames:
        bridge._consume_mavlink(frame, 2.0, PackedByteArray())

    var observed := bridge.px4_observability(2.25)
    assert_eq(observed.attitude.source, "px4_mavlink")
    assert_eq(observed.local_position_ned.sample.position_ned, Vector3(1.0, 2.0, -3.0))
    assert_eq(observed.attitude_target.sample.attitude_ned, Quaternion(0.2, 0.3, 0.4, 1.0))
    assert_almost_eq(observed.attitude_target.sample.thrust, 0.7, 0.00001)
    assert_eq(observed.position_target_local_ned.sample.position_ned, Vector3(7.0, 8.0, -9.0))
    assert_eq(observed.wind_cov.sample.wind_ned_mps, Vector3(2.0, 3.0, 4.0))
    assert_eq(observed.attitude.age_seconds, 0.25)
    assert_false(observed.has("body_torque_nm"))

    var invalid := _mavlink_frame(bridge, 30, _floats([99.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0]))
    invalid[10] ^= 0x01
    bridge._consume_mavlink(invalid, 3.0, PackedByteArray())
    assert_almost_eq(bridge.px4_observability(3.0).attitude.sample.roll_rad, 0.1, 0.00001)


func test_qualification_trace_bounds_finite_px4_attitude_and_local_position_freshness() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge.set_qualification_trace_enabled(true)
    var attitude_frame := _mavlink_frame(bridge, 30, _floats([10.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6]))
    var local_position_frame := _mavlink_frame(bridge, 32, _floats([10.0, 1.0, 2.0, -3.0, 4.0, 5.0, -6.0]))

    bridge._consume_mavlink(attitude_frame, 1.0, PackedByteArray())
    bridge._consume_mavlink(local_position_frame, 1.0, PackedByteArray())
    var fresh_entries := _qualification_trace_entries(bridge.qualification_trace(), "px4_stream_fresh")
    assert_eq(fresh_entries.size(), 2)
    assert_eq(fresh_entries[0].stream, "attitude")
    assert_eq(fresh_entries[0].source, "px4_mavlink")
    assert_almost_eq(fresh_entries[0].received_at_seconds, 1.0, 0.000001)
    assert_true(bool(fresh_entries[0].finite))
    assert_almost_eq(float(fresh_entries[0].sample.body_rates_frd_rad_s[0]), 0.4, 0.00001)
    assert_almost_eq(float(fresh_entries[0].sample.body_rates_frd_rad_s[1]), 0.5, 0.00001)
    assert_almost_eq(float(fresh_entries[0].sample.body_rates_frd_rad_s[2]), 0.6, 0.00001)
    assert_eq(fresh_entries[1].stream, "local_position_ned")
    assert_true(bool(fresh_entries[1].finite))
    assert_eq(fresh_entries[1].sample.position_ned, [1.0, 2.0, -3.0])
    assert_eq(fresh_entries[1].sample.velocity_ned_mps, [4.0, 5.0, -6.0])

    bridge._consume_mavlink(attitude_frame, 1.5, PackedByteArray())
    bridge._consume_mavlink(local_position_frame, 1.5, PackedByteArray())
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "px4_stream_fresh").size(), 2)
    bridge._consume_mavlink(attitude_frame, 2.1, PackedByteArray())
    bridge._consume_mavlink(local_position_frame, 2.1, PackedByteArray())
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "px4_stream_sample").size(), 4)

    bridge.poll(3.2)
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "px4_stream_stale").size(), 2)
    bridge._consume_mavlink(attitude_frame, 3.3, PackedByteArray())
    bridge._consume_mavlink(local_position_frame, 3.3, PackedByteArray())
    assert_eq(_qualification_trace_entries(bridge.qualification_trace(), "px4_stream_fresh").size(), 4)


func test_px4_actuator_commands_map_iris_wire_order_to_native_motor_order_and_fail_closed_when_stale() -> void:
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

    assert_eq(bridge.px4_observability(0.02).hil_actuator_controls.sample.command_normalized, {"m1": 1.0, "m2": 0.25, "m3": 0.5, "m4": 0.75})
    assert_eq(Array(bridge.actuator_outputs()), [1.0, 0.25, 0.5, 0.75])
    bridge.poll(0.12)
    assert_eq(bridge.actuator_outputs().size(), 0)
    assert_true(bridge.px4_observability(0.12).hil_actuator_controls.stale)


func test_px4_target_masks_and_unverified_hil_mapping_remain_unavailable() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge._config.HilActuatorQuadXOrder = ["front_right", "front_right", "front_left", "rear_right"]
    bridge.start()
    var attitude_payload := _floats([14.0, 1.0, 0.2, 0.3, 0.4, 0.1, 0.2, 0.3, 0.7]) + PackedByteArray([0x87])
    var position_payload := _floats([15.0, 7.0, 8.0, -9.0, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.4, 0.5]) + bridge._u16_bytes(0x0007) + PackedByteArray([1])
    bridge._consume_mavlink(_mavlink_frame(bridge, 83, attitude_payload), 0.01, PackedByteArray())
    bridge._consume_mavlink(_mavlink_frame(bridge, 85, position_payload), 0.01, PackedByteArray())
    var hil_payload := bridge._u64_bytes(1000)
    for _index in 8:
        hil_payload.append(0)
    for value in [0.25, 0.5, 0.75, 1.0]:
        hil_payload.append_array(bridge._float_bytes(value))
    for _index in 12:
        hil_payload.append_array(bridge._float_bytes(0.0))
    hil_payload.append(0x81)
    bridge._consume_mavlink(_mavlink_frame(bridge, 93, hil_payload), 0.01, PackedByteArray())

    var observed := bridge.px4_observability(0.02)
    assert_false(observed.attitude_target.sample.has("attitude_ned"))
    assert_false(observed.attitude_target.sample.has("body_rates_frd_rad_s"))
    assert_false(observed.position_target_local_ned.sample.has("position_ned"))
    assert_false(observed.hil_actuator_controls.sample.has("command_normalized"))
    assert_false(bool(observed.hil_actuator_controls.sample.mapping_verified))
    assert_eq(bridge.actuator_outputs().size(), 0)


func test_px4_hil_actuator_mapping_fails_closed_for_missing_or_unknown_motor_names() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge._config.HilActuatorQuadXOrder = ["front_right", "rear_left", "front_left"]
    bridge.start()
    assert_false(bridge._verified_quad_x_mapping())
    bridge._config.HilActuatorQuadXOrder = ["front_right", "rear_left", "front_left", "unknown"]
    assert_false(bridge._verified_quad_x_mapping())


func test_real_parser_accepts_crc_valid_mavlink_v2_trailing_zero_truncation() -> void:
    var bridge := _new_fake_bridge(1.0)
    bridge.start()
    bridge._consume_mavlink(_mavlink_v2_frame(bridge, 30, _floats([17.0, 0.1, 0.2, 0.3])), 2.0, PackedByteArray())
    bridge._consume_mavlink(_mavlink_v2_frame(bridge, 32, _floats([18.0, 1.0, 2.0, -3.0])), 2.0, PackedByteArray())
    bridge._consume_mavlink(_mavlink_v2_frame(bridge, 231, bridge._u64_bytes(19_000) + _floats([4.0, 5.0, 6.0])), 2.0, PackedByteArray())

    var observed := bridge.px4_observability(2.0)
    assert_almost_eq(observed.attitude.sample.roll_rad, 0.1, 0.00001)
    assert_eq(observed.attitude.sample.body_rates_frd_rad_s, Vector3.ZERO)
    assert_eq(observed.local_position_ned.sample.position_ned, Vector3(1.0, 2.0, -3.0))
    assert_eq(observed.local_position_ned.sample.velocity_ned_mps, Vector3.ZERO)
    assert_eq(observed.wind_cov.sample.wind_ned_mps, Vector3(4.0, 5.0, 6.0))
    assert_eq(observed.wind_cov.sample.horizontal_variance, 0.0)


func _floats(values: Array) -> PackedByteArray:
    var bytes := PackedByteArray()
    for value in values:
        bytes.append_array(Px4SitlBridgeScript.new()._float_bytes(float(value)))
    return bytes


func _estimator_status_payload(flags: int) -> PackedByteArray:
    var bridge := Px4SitlBridgeScript.new()
    var payload := bridge._u64_bytes(1_000_000)
    payload.append_array(_floats([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
    payload.append_array(bridge._u16_bytes(flags))
    return payload


func _u64_at(bytes: PackedByteArray, offset: int) -> int:
    var value := 0
    for index in 8:
        value |= int(bytes[offset + index]) << (index * 8)
    return value


func _i32_at(bytes: PackedByteArray, offset: int) -> int:
    var value := 0
    for index in 4:
        value |= int(bytes[offset + index]) << (index * 8)
    return value - 0x1_0000_0000 if value >= 0x8000_0000 else value


func _mavlink_frame(bridge: Px4SitlBridge, message_id: int, payload: PackedByteArray) -> PackedByteArray:
    var frame := PackedByteArray([0xFE, payload.size(), 0, 1, 1, message_id])
    frame.append_array(payload)
    var crc := bridge._mavlink_crc(frame.slice(1), bridge._crc_extra(message_id))
    frame.append(crc & 0xFF)
    frame.append((crc >> 8) & 0xFF)
    return frame


func _mavlink_v2_frame(bridge: Px4SitlBridge, message_id: int, payload: PackedByteArray) -> PackedByteArray:
    var frame := PackedByteArray([0xFD, payload.size(), 0, 0, 0, 1, 1, message_id, 0, 0])
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
        "LockStep": true,
        "HilActuatorQuadXOrder": ["front_right", "rear_left", "front_left", "rear_right"],
        "NativeMotorOrder": ["rear_right", "front_right", "rear_left", "front_left"],
    }, Callable(self, "_on_authority_changed"))
    return bridge


func _on_authority_changed(active: bool) -> void:
    authority_events.append(active)


func _qualification_trace_entry(trace: Array, kind: String) -> Dictionary:
    for index in range(trace.size() - 1, -1, -1):
        var entry: Dictionary = trace[index]
        if String(entry.get("kind", "")) == kind:
            return entry
    return {}


func _qualification_trace_entries(trace: Array, kind: String) -> Array:
    var entries: Array = []
    for entry in trace:
        if String(entry.get("kind", "")) == kind:
            entries.append(entry)
    return entries
