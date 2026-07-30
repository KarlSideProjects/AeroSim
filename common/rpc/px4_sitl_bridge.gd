class_name Px4SitlBridge
extends RefCounted

const MAVLINK_STX := 0xFE
const MAVLINK_STX_V2 := 0xFD
const MAVLINK_HEARTBEAT := 0
const MAVLINK_COMMAND_ACK := 77
const MAVLINK_ATTITUDE := 30
const MAVLINK_LOCAL_POSITION_NED := 32
const MAVLINK_ATTITUDE_TARGET := 83
const MAVLINK_POSITION_TARGET_LOCAL_NED := 85
const MAV_CMD_DO_SET_MODE := 176
const MAVLINK_HIL_ACTUATOR_CONTROLS := 93
const MAVLINK_ESTIMATOR_STATUS := 230
const MAVLINK_WIND_COV := 231
const MAV_MODE_FLAG_CUSTOM_MODE_ENABLED := 1
const PX4_CUSTOM_MAIN_MODE_OFFBOARD := 6
# Match AirSim's default simulator node IDs so PX4 does not treat control
# commands as self-originated messages from the vehicle (sysid 1).
const SIMULATOR_SYSTEM_ID := 142
const SIMULATOR_COMPONENT_ID := 42
const DEFAULT_HEARTBEAT_TIMEOUT := 2.0
const DEFAULT_FAILURE_TIMEOUT := 5.0
const ARM_ESTIMATOR_SETTLE_SECONDS := 8.0
const TAKEOFF_ESTIMATOR_SETTLE_SECONDS := 5.0
const ESTIMATOR_READY_REQUIRED_FLAGS := 63
const ESTIMATOR_READY_REPORT_COUNT := 2
const DEFAULT_TCP_PORT := 4560
const DEFAULT_CONTROL_PORT_LOCAL := 14540
const DEFAULT_CONTROL_PORT_REMOTE := 14580
const DEFAULT_UDP_PORT := 14560
const QUALIFICATION_TRACE_MAX_ENTRIES := 20000
const OFFBOARD_SETPOINT_PERIOD_SECONDS := 0.1
const OFFBOARD_PREWARM_SECONDS := 1.0
const HIL_SENSOR_IMU_UPDATED_MASK := 0x003F
const HIL_SENSOR_MAGNETOMETER_UPDATED_MASK := 0x01C0
const HIL_SENSOR_BAROMETER_UPDATED_MASK := 0x1A00

var state := "disconnected"
var mission_phase := "disarmed"
var last_setpoint := {
    "position_ned": Vector3.ZERO,
    "body_rates_frd": Vector3.ZERO,
}

var _config: Dictionary = {}
var _authority_callback: Callable
var _authority_active := false
var _last_heartbeat_time := -1.0
var _last_actuator_time := -1.0
# HIL_ACTUATOR_CONTROLS is timestamped in PX4's simulator clock. Keep it
# separate from Godot's wall-clock receive time for LockStep freshness.
var _last_actuator_simulation_time := -1.0
var _last_actuator_time_usec := -1
var _last_sensor_time := -1.0
var _hil_sensor_reset_sent := false
var _last_magnetometer_sample_time_ns := -1
var _last_barometer_sample_time_ns := -1
var _start_time := -1.0
var _armed_since := -1.0
var _arm_requested := false
var _arm_command_sent := false
var _hil_mode_requested := false
var _offboard_requested := false
var _offboard_target_active := false
var _offboard_prewarm_since := -1.0
var _last_position_setpoint_time := -1.0
var _takeoff_pending := false
var _takeoff_altitude := 0.0
var _estimator_ready_report_count := 0
var _last_estimator_ready_report_time := -1.0
var _last_outbound_heartbeat_time := -1.0
var _last_poll_time := -1.0
var _sequence := 0
var _target_system := 1
var _target_component := 1
var _last_command_id := -1
var _last_command_result := -1
var _pending_command_ids: Array[int] = []
var _message := ""
var _pending_heartbeat := -1
var _pending_actuators: Array = []
var _actuators := PackedFloat32Array()
var _px4_messages: Dictionary = {}
var _tcp: StreamPeerTCP
var _tcp_server: TCPServer
var _control_peer: PacketPeerUDP
var _tcp_rx_buffer := PackedByteArray()
var _control_rx_buffer := PackedByteArray()
var _qualification_trace_enabled := false
var _qualification_trace: Array[Dictionary] = []


func configure(vehicle_settings: Dictionary, authority_callback: Callable = Callable()) -> Dictionary:
    _config = {
        "VehicleType": vehicle_settings.get("VehicleType", "PX4Multirotor"),
        "Transport": vehicle_settings.get("Transport", "Real"),
        "UseSerial": vehicle_settings.get("UseSerial", false),
        "UseTcp": vehicle_settings.get("UseTcp", true),
        "TcpPort": int(vehicle_settings.get("TcpPort", DEFAULT_TCP_PORT)),
        "ControlIp": String(vehicle_settings.get("ControlIp", "127.0.0.1")),
        "ControlPortLocal": int(vehicle_settings.get("ControlPortLocal", DEFAULT_CONTROL_PORT_LOCAL)),
        "ControlPortRemote": int(vehicle_settings.get("ControlPortRemote", DEFAULT_CONTROL_PORT_REMOTE)),
        "LockStep": vehicle_settings.get("LockStep", true),
        "LocalHostIp": String(vehicle_settings.get("LocalHostIp", "127.0.0.1")),
        "UdpIp": String(vehicle_settings.get("UdpIp", "127.0.0.1")),
        "UdpPort": int(vehicle_settings.get("UdpPort", DEFAULT_UDP_PORT)),
        "HeartbeatTimeout": float(vehicle_settings.get("HeartbeatTimeout", DEFAULT_HEARTBEAT_TIMEOUT)),
        "FailureTimeout": float(vehicle_settings.get("FailureTimeout", DEFAULT_FAILURE_TIMEOUT)),
        "ActuatorTimeout": float(vehicle_settings.get("ActuatorTimeout", 0.5)),
        "HilActuatorQuadXOrder": vehicle_settings.get("HilActuatorQuadXOrder", []),
        "NativeMotorOrder": vehicle_settings.get("NativeMotorOrder", []),
    }
    _authority_callback = authority_callback
    var errors: Array[String] = []
    if _config.VehicleType != "PX4Multirotor":
        errors.append("PX4 SITL bridge requires VehicleType PX4Multirotor")
    if _config.UseSerial:
        errors.append("PX4 SITL bridge does not support serial/HITL transport")
    if not _valid_port(_config.TcpPort) or not _valid_port(_config.ControlPortLocal) or not _valid_port(_config.ControlPortRemote) or not _valid_port(_config.UdpPort):
        errors.append("PX4 SITL bridge ports must be in the range 1..65535")
    if _config.HeartbeatTimeout <= 0.0 or _config.ActuatorTimeout <= 0.0 or _config.FailureTimeout <= _config.HeartbeatTimeout:
        errors.append("PX4 SITL bridge timeouts must be positive and ordered")
    if not errors.is_empty():
        _message = "; ".join(errors)
        state = "failed"
        return {"ok": false, "error": _message}
    state = "disconnected"
    _message = ""
    return {"ok": true}


func start() -> Dictionary:
    if state == "failed":
        return {"ok": false, "error": _message}
    _last_heartbeat_time = -1.0
    _last_actuator_time = -1.0
    _last_actuator_simulation_time = -1.0
    _last_actuator_time_usec = -1
    _last_sensor_time = -1.0
    _hil_sensor_reset_sent = false
    _last_magnetometer_sample_time_ns = -1
    _last_barometer_sample_time_ns = -1
    _armed_since = -1.0
    _arm_requested = false
    _arm_command_sent = false
    _hil_mode_requested = false
    _offboard_requested = false
    _offboard_target_active = false
    _offboard_prewarm_since = -1.0
    _last_position_setpoint_time = -1.0
    _takeoff_pending = false
    _takeoff_altitude = 0.0
    _estimator_ready_report_count = 0
    _last_estimator_ready_report_time = -1.0
    _last_outbound_heartbeat_time = -1.0
    _actuators = PackedFloat32Array()
    _px4_messages.clear()
    _sequence = 0
    _target_system = 1
    _target_component = 1
    _last_command_id = -1
    _last_command_result = -1
    _pending_command_ids.clear()
    _tcp_rx_buffer.clear()
    _control_rx_buffer.clear()
    if _config.get("Transport") == "Fake":
        state = "starting"
        _message = "waiting for PX4 heartbeat"
        _start_time = -1.0
        return {"ok": true}
    if not _config.UseTcp:
        state = "failed"
        _message = "PX4 SITL requires UseTcp=true"
        return {"ok": false, "error": _message}
    _tcp_server = TCPServer.new()
    var tcp_result := _tcp_server.listen(_config.TcpPort, _config.LocalHostIp)
    if tcp_result != OK:
        state = "failed"
        _message = "PX4 simulator TCP connection failed: %s" % tcp_result
        return {"ok": false, "error": _message}
    _control_peer = PacketPeerUDP.new()
    var udp_result := _control_peer.bind(_config.ControlPortLocal, _config.LocalHostIp)
    if udp_result != OK:
        state = "failed"
        _message = "PX4 control UDP bind failed on %s:%d: %s" % [_config.ControlIp, _config.ControlPortLocal, udp_result]
        return {"ok": false, "error": _message}
    _control_peer.set_dest_address(_config.ControlIp, _config.ControlPortRemote)
    _send_simulator_heartbeat()
    _send_command_long_parameters(511, [0.0, 1000000.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    _send_command_long_parameters(512, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    state = "starting"
    _message = "waiting for PX4 heartbeat"
    _start_time = -1.0
    return {"ok": true}


func poll(now_seconds: float) -> void:
    _last_poll_time = now_seconds
    if _start_time < 0.0 and state == "starting":
        _start_time = now_seconds
    if _config.get("Transport") == "Fake":
        _consume_fake(now_seconds)
    else:
        if _last_outbound_heartbeat_time < 0.0 or now_seconds - _last_outbound_heartbeat_time >= 1.0:
            _send_simulator_heartbeat()
            _last_outbound_heartbeat_time = now_seconds
        _poll_real(now_seconds)
    if _last_heartbeat_time < 0.0:
        if _start_time >= 0.0 and now_seconds - _start_time + 0.000001 >= _config.FailureTimeout:
            _set_state("failed", false, "PX4 heartbeat was not received before startup timeout")
        return
    _progress_arm_readiness(now_seconds)
    if state == "failed":
        return
    _advance_offboard_setpoint_publisher(now_seconds)
    var actuator_started_after_arm := _actuator_received_after_arm()
    if state == "armed" and actuator_started_after_arm and _actuator_freshness_age_seconds(now_seconds) + 0.000001 >= _config.ActuatorTimeout:
        _clear_offboard_target()
        _trace_qualification_event("actuator_freshness_expired", now_seconds, {
            "age_seconds": _actuator_freshness_age_seconds(now_seconds),
            "uses_source_clock": _uses_source_clock_for_actuator_freshness(),
            "last_sensor_time": _last_sensor_time,
            "last_actuator_simulation_time": _last_actuator_simulation_time,
            "last_actuator_time_usec": _last_actuator_time_usec,
        })
        _actuators = PackedFloat32Array()
        _set_state("stale", false, "PX4 actuator output is stale")
        return
    # A real LockStep control loop advances only as HIL_SENSOR advances. Once
    # PX4 has provided an actuator source timestamp, wall-clock heartbeat gaps
    # are not evidence of an inactive controller.
    if _uses_source_clock_for_actuator_freshness():
        return
    var age := now_seconds - _last_heartbeat_time
    if age + 0.000001 >= _config.FailureTimeout:
        _set_state("failed", false, "PX4 heartbeat timeout after %.3f seconds" % age)
    elif age > _config.HeartbeatTimeout and state not in ["stale", "failed"]:
        _set_state("stale", false, "PX4 heartbeat is stale after %.3f seconds" % age)


func publish_sensor_snapshot(snapshot: Dictionary, simulation_time_seconds: float) -> void:
    _last_sensor_time = simulation_time_seconds
    if _config.get("Transport") == "Fake" or not _tcp_connected():
        return
    var measurements := hil_sensor_measurements(snapshot)
    if not bool(measurements.get("ok", false)):
        _trace_qualification_event("outgoing_hil_sensor_rejected", _last_poll_time, {
            "simulation_time_seconds": simulation_time_seconds,
            "error": String(measurements.get("error", "missing sensor measurement")),
        })
        return
    var accel: Vector3 = measurements.accel_mps2
    var gyro: Vector3 = measurements.gyro_rad_s
    var magnetic_field: Vector3 = measurements.magnetic_field_gauss
    var barometer_altitude := float(measurements.barometer_altitude_m)
    var absolute_pressure_hpa := float(measurements.absolute_pressure_hpa)
    var sensor_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    for value in [
        accel.x, accel.y, accel.z,
        gyro.x, gyro.y, gyro.z,
        magnetic_field.x, magnetic_field.y, magnetic_field.z,
        absolute_pressure_hpa, 0.0, barometer_altitude, float(measurements.temperature_c)
    ]:
        sensor_payload.append_array(_float_bytes(value))
    var fields_updated := hil_sensor_fields_updated(snapshot)
    sensor_payload.append_array(_u32_bytes(fields_updated))
    sensor_payload.append(0)
    _send_mavlink(sensor_payload, 107, _tcp)
    _trace_qualification_event("outgoing_hil_sensor", _last_poll_time, {
        "simulation_time_seconds": simulation_time_seconds,
        "time_usec": int(round(simulation_time_seconds * 1_000_000.0)),
        "fields_updated": fields_updated,
        "accel_mps2": [accel.x, accel.y, accel.z],
        "gyro_rad_s": [gyro.x, gyro.y, gyro.z],
        "magnetic_field_body": [magnetic_field.x, magnetic_field.y, magnetic_field.z],
        "barometer_altitude_m": barometer_altitude,
        "absolute_pressure_hpa": absolute_pressure_hpa,
        "temperature_c": float(measurements.temperature_c),
    })

    var system_time_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    system_time_payload.append_array(_u32_bytes(int(round(simulation_time_seconds * 1_000.0))))
    _send_mavlink(system_time_payload, 2, _tcp)

    var velocity_ned: Vector3 = measurements.velocity_ned
    var gps: Dictionary = snapshot.get("gps_location", {})
    var gps_payload := _hil_gps_payload(
        int(round(simulation_time_seconds * 1_000_000.0)),
        float(gps.get("latitude", 0.0)),
        float(gps.get("longitude", 0.0)),
        float(gps.get("altitude", 0.0)),
        velocity_ned)
    _send_mavlink(gps_payload, 113, _tcp)


func hil_sensor_measurements(snapshot: Dictionary) -> Dictionary:
    var estimate: Variant = snapshot.get("kinematics_estimated")
    var imu: Variant = snapshot.get("imu_sample")
    var magnetometer: Variant = snapshot.get("magnetometer")
    var barometer: Variant = snapshot.get("barometer")
    if not (estimate is Dictionary) or not (imu is Dictionary) or not (magnetometer is Dictionary) or not (barometer is Dictionary):
        return {"ok": false, "error": "HIL sensor snapshot requires kinematics, IMU, magnetometer, and barometer measurements"}
    var accel: Variant = _finite_vector3(imu.get("accel"))
    var gyro: Variant = _finite_vector3(imu.get("gyro"))
    var magnetic_field: Variant = _finite_vector3(magnetometer.get("magnetic_field_body"))
    var velocity: Variant = _finite_vector3(estimate.get("linear_velocity"))
    var barometer_altitude: Variant = barometer.get("altitude_m")
    var absolute_pressure: Variant = barometer.get("pressure_hpa")
    var temperature: Variant = barometer.get("temperature_c")
    if accel == null or gyro == null or magnetic_field == null or velocity == null or not _finite_number(barometer_altitude) or not _finite_number(absolute_pressure) or not _finite_number(temperature) or float(absolute_pressure) <= 0.0:
        return {"ok": false, "error": "HIL sensor snapshot contains missing or non-finite measurements"}
    return {
        "ok": true,
        "accel_mps2": accel,
        "gyro_rad_s": gyro,
        "magnetic_field_gauss": magnetic_field,
        "velocity_ned": velocity,
        "barometer_altitude_m": float(barometer_altitude),
        "absolute_pressure_hpa": float(absolute_pressure),
        "temperature_c": float(temperature),
    }


func hil_sensor_fields_updated(snapshot: Dictionary) -> int:
    if not _hil_sensor_reset_sent:
        _hil_sensor_reset_sent = true
        return 1 << 31
    var fields_updated := HIL_SENSOR_IMU_UPDATED_MASK
    var magnetometer_time_ns := _sensor_sample_time_ns(snapshot.get("magnetometer"))
    var barometer_time_ns := _sensor_sample_time_ns(snapshot.get("barometer"))
    if magnetometer_time_ns > _last_magnetometer_sample_time_ns:
        fields_updated |= HIL_SENSOR_MAGNETOMETER_UPDATED_MASK
        _last_magnetometer_sample_time_ns = magnetometer_time_ns
    if barometer_time_ns > _last_barometer_sample_time_ns:
        fields_updated |= HIL_SENSOR_BAROMETER_UPDATED_MASK
        _last_barometer_sample_time_ns = barometer_time_ns
    return fields_updated


func _sensor_sample_time_ns(sensor: Variant) -> int:
    if not (sensor is Dictionary):
        return -1
    var sample_time: Variant = sensor.get("time_stamp")
    return int(sample_time) if sample_time is int or sample_time is float else -1


func _finite_vector3(value: Variant) -> Variant:
    if not (value is Dictionary):
        return null
    var x: Variant = value.get("x_val")
    var y: Variant = value.get("y_val")
    var z: Variant = value.get("z_val")
    if not _finite_number(x) or not _finite_number(y) or not _finite_number(z):
        return null
    return Vector3(float(x), float(y), float(z))


func _finite_number(value: Variant) -> bool:
    return (value is float or value is int) and is_finite(float(value))


func _hil_gps_payload(time_usec: int, latitude: float, longitude: float, altitude_m: float, velocity_ned: Vector3) -> PackedByteArray:
    var payload := _u64_bytes(time_usec)
    payload.append_array(_i32_bytes(int(round(latitude * 10_000_000.0))))
    payload.append_array(_i32_bytes(int(round(longitude * 10_000_000.0))))
    payload.append_array(_i32_bytes(int(round(altitude_m * 1000.0))))
    payload.append_array(_u16_bytes(100))
    payload.append_array(_u16_bytes(100))
    payload.append_array(_u16_bytes(int(round(velocity_ned.length() * 100.0))))
    payload.append_array(_i16_bytes(int(round(velocity_ned.x * 100.0))))
    payload.append_array(_i16_bytes(int(round(velocity_ned.y * 100.0))))
    payload.append_array(_i16_bytes(int(round(velocity_ned.z * 100.0))))
    payload.append_array(_u16_bytes(0))
    # The generated PX4 MAVLink header packs fix_type at payload offset 34.
    payload.append(3)
    payload.append(10)
    payload.append(0)
    payload.append_array(_u16_bytes(0))
    return payload


func inject_heartbeat(armed: bool) -> void:
    _pending_heartbeat = 1 if armed else 0


func inject_actuators(outputs: Array) -> void:
    _pending_actuators = outputs.duplicate()


func arm_disarm(armed: bool) -> Dictionary:
    if state not in ["connected", "armed"]:
        return {"ok": false, "error": "PX4 is not connected"}
    if _config.get("Transport") == "Fake":
        if armed:
            mission_phase = "armed_pending"
            _arm_requested = true
        else:
            mission_phase = "disarmed"
            _arm_requested = false
            _set_state("connected", false, "PX4 disarmed")
        return {"ok": true}
    _arm_requested = armed
    if not armed:
        _clear_offboard_target()
        _send_command_long(400, 0.0)
    return {"ok": true, "armed": state == "armed" if armed else state == "connected"}


func takeoff(position_ned: Vector3) -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "takeoff"
    if _config.get("Transport") != "Fake":
        # AirSim waits for home/stable-ground readiness before sending PX4's
        # takeoff command. HIL estimator startup is asynchronous, so defer
        # the command until the armed heartbeat has had one settle interval.
        _takeoff_pending = true
        _takeoff_altitude = -position_ned.z
        return {"ok": true, "pending": true}
    return {"ok": true}


func move_to_position(position_ned: Vector3) -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "waypoint"
    return setpoint_ned_frd(position_ned, Vector3.ZERO)


func hover() -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "hover"
    if _config.get("Transport") != "Fake":
        return setpoint_ned_frd(last_setpoint.position_ned, Vector3.ZERO)
    return {"ok": true}


func land() -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "land"
    _clear_offboard_target()
    if _config.get("Transport") != "Fake":
        _send_command_long(21, 0.0, 0.0)
    return {"ok": true}


func setpoint_ned_frd(position_ned: Vector3, body_rates_frd: Vector3) -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    last_setpoint = {
        "position_ned": position_ned,
        "body_rates_frd": body_rates_frd,
    }
    _trace_qualification_event("setpoint_requested", _last_poll_time, {
        "position_ned": position_ned,
        "body_rates_frd": body_rates_frd,
        "mission_phase": mission_phase,
    })
    if _config.get("Transport") != "Fake":
        _offboard_target_active = true
        _offboard_prewarm_since = -1.0
        _last_position_setpoint_time = -1.0
    return {"ok": true}


func _advance_offboard_setpoint_publisher(now_seconds: float) -> void:
    if _config.get("Transport") == "Fake" or not _offboard_target_active:
        return
    if not is_authority_active() or not estimator_ready(now_seconds):
        _clear_offboard_target()
        return
    if _offboard_prewarm_since < 0.0:
        _offboard_prewarm_since = now_seconds
    if _last_position_setpoint_time < 0.0 or now_seconds - _last_position_setpoint_time >= OFFBOARD_SETPOINT_PERIOD_SECONDS:
        _send_position_setpoint(last_setpoint.position_ned)
        _last_position_setpoint_time = now_seconds
    if not _offboard_requested and now_seconds - _offboard_prewarm_since >= OFFBOARD_PREWARM_SECONDS:
        _send_command_long_parameters(MAV_CMD_DO_SET_MODE, [MAV_MODE_FLAG_CUSTOM_MODE_ENABLED, PX4_CUSTOM_MAIN_MODE_OFFBOARD])
        _offboard_requested = true


func _clear_offboard_target() -> void:
    _offboard_target_active = false
    _offboard_prewarm_since = -1.0
    _last_position_setpoint_time = -1.0
    _offboard_requested = false


func _send_position_setpoint(position_ned: Vector3) -> void:
    var payload := PackedByteArray()
    payload.append_array(_u32_bytes(int(round(maxf(_last_poll_time, 0.0) * 1000.0))))
    for value in [
        position_ned.x, position_ned.y, position_ned.z,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        0.0, 0.0
    ]:
        payload.append_array(_float_bytes(value))
    payload.append_array(_u16_bytes(3576))
    payload.append(_target_system)
    payload.append(_target_component)
    payload.append(1)
    _trace_qualification_event("outgoing_position_setpoint", _last_poll_time, {
        "position_ned": position_ned,
        "type_mask": 3576,
        "target_system": _target_system,
        "target_component": _target_component,
        "offboard_requested": _offboard_requested,
    })
    _send_mavlink(payload, 84, _control_peer)


func is_authority_active() -> bool:
    return _authority_active and state in ["connected", "armed"]


func lockstep_enabled() -> bool:
    return bool(_config.get("LockStep", false))


func lockstep_active() -> bool:
    # Startup and arm-command retries must keep publishing sensors until PX4
    # reports an armed heartbeat; gating on the request itself deadlocks PX4
    # before it can emit its first actuator frame.
    return lockstep_enabled() and state in ["armed", "stale"]


func estimator_ready(now_seconds: float) -> bool:
    return _estimator_ready_report_count >= ESTIMATOR_READY_REPORT_COUNT \
        and _last_estimator_ready_report_time >= 0.0 \
        and now_seconds - _last_estimator_ready_report_time < float(_config.HeartbeatTimeout)


func actuator_outputs() -> PackedFloat32Array:
    # High Fidelity has no native fallback: stale or unarmed PX4 output must
    # not advance the native controller with a previous command.
    return _actuators if is_authority_active() else PackedFloat32Array()


func px4_observability(now_seconds: float) -> Dictionary:
    var observed: Dictionary = {}
    for name in _px4_messages:
        var entry: Dictionary = _px4_messages[name]
        var age_seconds := maxf(0.0, now_seconds - float(entry.received_at_seconds))
        var freshness_timeout := float(_config.ActuatorTimeout) if name == "hil_actuator_controls" else float(_config.HeartbeatTimeout)
        if name == "hil_actuator_controls":
            age_seconds = _actuator_freshness_age_seconds(now_seconds)
        observed[name] = {
            "source": "px4_mavlink",
            "age_seconds": age_seconds,
            "stale": age_seconds >= freshness_timeout,
            "sample": entry.sample.duplicate(true),
        }
    var actuator_age_seconds := _actuator_freshness_age_seconds(now_seconds)
    observed["bridge_diagnostics"] = {
        # This entry is bridge-owned runtime state, deliberately not a PX4
        # MAVLink message. Consumers must retain the source label rather than
        # rendering it as an FCU telemetry sample.
        "source": "px4_bridge",
        "age_seconds": actuator_age_seconds,
        "stale": state in ["stale", "failed"],
        "sample": {
            "state": state,
            "authority_active": _authority_active,
            "estimator_ready": estimator_ready(now_seconds),
            "mission_phase": mission_phase,
            "last_command_result": _last_command_result,
            "actuator_freshness_age_seconds": actuator_age_seconds,
        },
    }
    return observed


func diagnostics() -> Dictionary:
    return {
        "state": state,
        "message": _message,
        "last_heartbeat_time": _last_heartbeat_time,
        "last_actuator_time": _last_actuator_time,
        "last_actuator_simulation_time": _last_actuator_simulation_time,
        "last_actuator_time_usec": _last_actuator_time_usec,
        "last_sensor_time": _last_sensor_time,
        "actuator_freshness_age_seconds": _actuator_freshness_age_seconds(_last_poll_time),
        "estimator_ready": estimator_ready(_last_poll_time),
        "estimator_ready_report_count": _estimator_ready_report_count,
        "last_estimator_ready_report_time": _last_estimator_ready_report_time,
        "authority_active": _authority_active,
        "mission_phase": mission_phase,
        "last_command_id": _last_command_id,
        "last_command_result": _last_command_result,
        "pending_command_ids": _pending_command_ids.duplicate(),
    }


# Qualification runs opt into this raw bridge trace so a failed real PX4 run
# can be diagnosed from the actual incoming frames without changing authority
# or failsafe behavior. It is intentionally not published through the GSP API.
func set_qualification_trace_enabled(enabled: bool) -> void:
    _qualification_trace_enabled = enabled
    _qualification_trace.clear()


func qualification_trace() -> Array:
    return _qualification_trace.duplicate(true)


func stop() -> void:
    if _control_peer != null:
        _control_peer.close()
    if _tcp != null:
        _tcp.disconnect_from_host()
    _tcp = null
    _tcp_server = null
    _control_peer = null
    _arm_requested = false
    _arm_command_sent = false
    _takeoff_pending = false
    _estimator_ready_report_count = 0
    _last_estimator_ready_report_time = -1.0
    _pending_command_ids.clear()
    _set_state("disconnected", false, "PX4 transport stopped")


func _consume_fake(now_seconds: float) -> void:
    if _pending_heartbeat >= 0:
        var armed := _pending_heartbeat == 1
        _pending_heartbeat = -1
        _last_heartbeat_time = now_seconds
        _update_armed_since(armed, now_seconds)
        if armed:
            _arm_requested = false
        _refresh_authority(now_seconds, armed)
    if not _pending_actuators.is_empty():
        _actuators = PackedFloat32Array(_pending_actuators)
        _pending_actuators.clear()
        _last_actuator_time = now_seconds
        if _armed_since >= 0.0:
            _refresh_authority(now_seconds, true)


func _poll_real(now_seconds: float) -> void:
    if _tcp_server == null or _control_peer == null:
        return
    if _tcp == null and _tcp_server.is_connection_available():
        _tcp = _tcp_server.take_connection()
        _message = "PX4 TCP simulator channel connected"
    if _tcp_connected():
        _tcp.poll()
        var available_bytes := _tcp.get_available_bytes()
        if available_bytes < 0:
            _tcp = null
            _tcp_rx_buffer.clear()
            _message = "PX4 simulator TCP channel disconnected"
        elif available_bytes > 0:
            var packet_result: Array = _tcp.get_data(available_bytes)
            if packet_result.size() >= 2 and int(packet_result[0]) == OK:
                _tcp_rx_buffer = _consume_mavlink(packet_result[1], now_seconds, _tcp_rx_buffer)
    elif _tcp != null:
        _tcp = null
        _tcp_rx_buffer.clear()
        _message = "PX4 simulator TCP channel disconnected"
    while _control_peer.get_available_packet_count() > 0:
        var packet := _control_peer.get_packet()
        _control_rx_buffer = _consume_mavlink(packet, now_seconds, _control_rx_buffer)
    if _takeoff_pending and _armed_since >= 0.0 and now_seconds - _armed_since >= TAKEOFF_ESTIMATOR_SETTLE_SECONDS:
        _send_command_long(22, 0.0, _takeoff_altitude)
        _takeoff_pending = false


func _consume_mavlink(packet: PackedByteArray, now_seconds: float, rx_buffer: PackedByteArray) -> PackedByteArray:
    rx_buffer.append_array(packet)
    while rx_buffer.size() >= 8:
        var start := _find_mavlink_start(rx_buffer)
        if start < 0:
            rx_buffer.clear()
            return rx_buffer
        if start > 0:
            rx_buffer = rx_buffer.slice(start)
        if rx_buffer.size() < 8:
            return rx_buffer
        var payload_size := int(rx_buffer[1])
        var v2 := rx_buffer[0] == MAVLINK_STX_V2
        var header_size := 10 if v2 else 6
        if rx_buffer.size() < header_size + 2:
            return rx_buffer
        var frame_size := payload_size + header_size + 2
        if v2 and (int(rx_buffer[2]) & 0x01) != 0:
            frame_size += 13
        if rx_buffer.size() < frame_size:
            return rx_buffer
        var frame := rx_buffer.slice(0, frame_size)
        rx_buffer = rx_buffer.slice(frame_size)
        if not _mavlink_crc_valid(frame):
            continue
        var payload_offset := 10 if v2 else 6
        var message_id := _message_id(frame)
        if message_id == MAVLINK_HEARTBEAT:
            if payload_size < 9:
                continue
            _last_heartbeat_time = now_seconds
            _target_system = int(frame[5] if v2 else frame[3])
            _target_component = int(frame[6] if v2 else frame[4])
            var base_mode := int(frame[payload_offset + 6])
            var custom_mode := int(frame.decode_u32(payload_offset))
            if not _hil_mode_requested and (base_mode & 0x20) == 0:
                _send_command_long(MAV_CMD_DO_SET_MODE, float(base_mode | 0x20))
                _hil_mode_requested = true
            var armed := (base_mode & 0x80) != 0
            _update_armed_since(armed, now_seconds)
            if armed:
                _arm_requested = false
            var state_before := state
            var authority_before := _authority_active
            _refresh_authority(now_seconds, armed)
            _trace_qualification_event("heartbeat", now_seconds, {
                "base_mode": base_mode,
                "custom_mode": custom_mode,
                "armed": armed,
                "state_before": state_before,
                "authority_before": authority_before,
            })
        elif message_id == MAVLINK_HIL_ACTUATOR_CONTROLS:
            if payload_size < 81:
                continue
            # PX4's generated common dialect packs this message as time_usec
            # (8), flags (8), controls[16] (64), and mode (1).
            var actuator_time_usec := _payload_u64(frame, payload_offset, payload_size, 0)
            if _last_actuator_time_usec >= 0 and actuator_time_usec < _last_actuator_time_usec:
                _trace_qualification_event("hil_actuator_controls_rejected", now_seconds, {
                    "time_usec": actuator_time_usec,
                    "last_time_usec": _last_actuator_time_usec,
                    "error": "HIL actuator source timestamp regressed",
                })
                continue
            var armed := (int(frame[payload_offset + 80]) & 0x80) != 0
            var raw_controls := PackedFloat32Array()
            for index in 4:
                raw_controls.append(clampf(frame.decode_float(payload_offset + 16 + index * 4), 0.0, 1.0) if armed else 0.0)
            var native_indices := _hil_to_native_motor_indices()
            var hil_sample := {"mapping_verified": native_indices.size() == 4}
            if bool(hil_sample.mapping_verified):
                _actuators = PackedFloat32Array()
                for source_index in native_indices:
                    _actuators.append(raw_controls[source_index])
                _last_actuator_time = now_seconds
                _last_actuator_simulation_time = float(actuator_time_usec) / 1_000_000.0
                _last_actuator_time_usec = actuator_time_usec
                hil_sample["command_normalized"] = {
                    "m1": float(_actuators[0]), "m2": float(_actuators[1]),
                    "m3": float(_actuators[2]), "m4": float(_actuators[3]),
                }
            else:
                _actuators = PackedFloat32Array()
            _record_px4_message("hil_actuator_controls", hil_sample, now_seconds)
            var state_before := state
            var authority_before := _authority_active
            if _armed_since >= 0.0:
                _refresh_authority(now_seconds, true)
            _trace_qualification_event("hil_actuator_controls", now_seconds, {
                "mode_byte": int(frame[payload_offset + 80]),
                "flags": _payload_u64(frame, payload_offset, payload_size, 8),
                "time_usec": actuator_time_usec,
                "simulation_time_seconds": _last_actuator_simulation_time,
                "armed": armed,
                "raw_outputs": Array(raw_controls),
                "outputs": Array(_actuators),
                "mapping_verified": bool(hil_sample.mapping_verified),
                "source_motor_order": _config.get("HilActuatorQuadXOrder", []),
                "native_motor_order": _config.get("NativeMotorOrder", []),
                "state_before": state_before,
                "authority_before": authority_before,
            })
        elif message_id == MAVLINK_ESTIMATOR_STATUS:
            if payload_size < 42:
                continue
            var flags := int(frame.decode_u16(payload_offset + 40))
            var required_flags_present := (flags & ESTIMATOR_READY_REQUIRED_FLAGS) == ESTIMATOR_READY_REQUIRED_FLAGS
            if required_flags_present:
                if _last_estimator_ready_report_time >= 0.0 and now_seconds - _last_estimator_ready_report_time < float(_config.HeartbeatTimeout):
                    _estimator_ready_report_count += 1
                else:
                    _estimator_ready_report_count = 1
                _last_estimator_ready_report_time = now_seconds
            else:
                _estimator_ready_report_count = 0
                _last_estimator_ready_report_time = -1.0
            var estimator_sample := {
                "time_usec": _payload_u64(frame, payload_offset, payload_size, 0),
                "flags": flags,
                "vel_ratio": _payload_float(frame, payload_offset, payload_size, 8),
                "pos_horiz_ratio": _payload_float(frame, payload_offset, payload_size, 12),
                "pos_vert_ratio": _payload_float(frame, payload_offset, payload_size, 16),
                "estimator_ready": estimator_ready(now_seconds),
                "ready_report_count": _estimator_ready_report_count,
            }
            _record_px4_message("estimator_status", estimator_sample, now_seconds)
            _trace_qualification_event("estimator_status", now_seconds, estimator_sample)
        elif message_id == MAVLINK_ATTITUDE:
            if not v2 and payload_size < 28:
                continue
            _record_px4_message("attitude", {
                "roll_rad": _payload_float(frame, payload_offset, payload_size, 4),
                "pitch_rad": _payload_float(frame, payload_offset, payload_size, 8),
                "yaw_rad": _payload_float(frame, payload_offset, payload_size, 12),
                "body_rates_frd_rad_s": Vector3(_payload_float(frame, payload_offset, payload_size, 16), _payload_float(frame, payload_offset, payload_size, 20), _payload_float(frame, payload_offset, payload_size, 24)),
            }, now_seconds)
        elif message_id == MAVLINK_LOCAL_POSITION_NED:
            if not v2 and payload_size < 28:
                continue
            _record_px4_message("local_position_ned", {
                "position_ned": Vector3(_payload_float(frame, payload_offset, payload_size, 4), _payload_float(frame, payload_offset, payload_size, 8), _payload_float(frame, payload_offset, payload_size, 12)),
                "velocity_ned_mps": Vector3(_payload_float(frame, payload_offset, payload_size, 16), _payload_float(frame, payload_offset, payload_size, 20), _payload_float(frame, payload_offset, payload_size, 24)),
            }, now_seconds)
        elif message_id == MAVLINK_ATTITUDE_TARGET:
            if payload_size < 37:
                continue
            var attitude_mask := int(frame[payload_offset + 36])
            var attitude_target := {"type_mask": attitude_mask}
            if (attitude_mask & 0x80) == 0:
                attitude_target["attitude_ned"] = Quaternion(frame.decode_float(payload_offset + 8), frame.decode_float(payload_offset + 12), frame.decode_float(payload_offset + 16), frame.decode_float(payload_offset + 4))
            if (attitude_mask & 0x07) == 0:
                attitude_target["body_rates_frd_rad_s"] = Vector3(frame.decode_float(payload_offset + 20), frame.decode_float(payload_offset + 24), frame.decode_float(payload_offset + 28))
            attitude_target["thrust"] = frame.decode_float(payload_offset + 32)
            _record_px4_message("attitude_target", attitude_target, now_seconds)
        elif message_id == MAVLINK_POSITION_TARGET_LOCAL_NED:
            if payload_size < 51:
                continue
            var position_mask := int(frame.decode_u16(payload_offset + 48))
            var coordinate_frame := int(frame[payload_offset + 50])
            if coordinate_frame != 1:
                continue
            var position_target := {"type_mask": position_mask, "coordinate_frame": coordinate_frame}
            if (position_mask & 0x07) == 0:
                position_target["position_ned"] = Vector3(frame.decode_float(payload_offset + 4), frame.decode_float(payload_offset + 8), frame.decode_float(payload_offset + 12))
            if (position_mask & 0x38) == 0:
                position_target["velocity_ned_mps"] = Vector3(frame.decode_float(payload_offset + 16), frame.decode_float(payload_offset + 20), frame.decode_float(payload_offset + 24))
            if (position_mask & 0x400) == 0:
                position_target["yaw_rad"] = frame.decode_float(payload_offset + 40)
            if (position_mask & 0x800) == 0:
                position_target["yaw_rate_rad_s"] = frame.decode_float(payload_offset + 44)
            _record_px4_message("position_target_local_ned", position_target, now_seconds)
        elif message_id == MAVLINK_WIND_COV:
            if not v2 and payload_size < 40:
                continue
            _record_px4_message("wind_cov", {
                "wind_ned_mps": Vector3(_payload_float(frame, payload_offset, payload_size, 8), _payload_float(frame, payload_offset, payload_size, 12), _payload_float(frame, payload_offset, payload_size, 16)),
                "horizontal_variance": _payload_float(frame, payload_offset, payload_size, 20),
                "vertical_variance": _payload_float(frame, payload_offset, payload_size, 24),
            }, now_seconds)
        elif message_id == MAVLINK_COMMAND_ACK:
            if payload_size < 3:
                continue
            var command := int(frame.decode_u16(payload_offset))
            var result := int(frame[payload_offset + 2])
            var tracked := _pending_command_ids.has(command)
            _trace_qualification_event("command_ack", now_seconds, {
                "command": command,
                "result": result,
                "tracked": tracked,
            })
            if tracked:
                _last_command_result = result
                if result == 5:
                    continue
                _pending_command_ids.erase(command)
                if command == 400 and result == 1:
                    _arm_command_sent = false
                if result not in [0, 1]:
                    if command == 400:
                        _arm_requested = false
                    _set_state("failed", false, "PX4 command %d rejected with result %d" % [command, result])
    return rx_buffer


func _verified_quad_x_mapping() -> bool:
    return _hil_to_native_motor_indices().size() == 4


func _hil_to_native_motor_indices() -> Array[int]:
    var source_order: Variant = _config.get("HilActuatorQuadXOrder", [])
    var native_order: Variant = _config.get("NativeMotorOrder", [])
    if not _valid_motor_order(source_order) or not _valid_motor_order(native_order):
        return []
    var indices: Array[int] = []
    for motor_name_value in native_order:
        var source_index: int = source_order.find(motor_name_value)
        if source_index < 0:
            return []
        indices.append(source_index)
    return indices


func _valid_motor_order(order: Variant) -> bool:
    if not order is Array or order.size() != 4:
        return false
    var names := {}
    for motor_name_value in order:
        if typeof(motor_name_value) != TYPE_STRING:
            return false
        var motor_name := String(motor_name_value)
        if motor_name.is_empty() or names.has(motor_name):
            return false
        names[motor_name] = true
    return true


func _find_mavlink_start(rx_buffer: PackedByteArray) -> int:
    var v1_start := rx_buffer.find(MAVLINK_STX)
    var v2_start := rx_buffer.find(MAVLINK_STX_V2)
    if v1_start < 0:
        return v2_start
    if v2_start < 0:
        return v1_start
    return mini(v1_start, v2_start)


func _record_px4_message(name: String, sample: Dictionary, now_seconds: float) -> void:
    _px4_messages[name] = {"received_at_seconds": now_seconds, "sample": sample}


func _payload_float(frame: PackedByteArray, payload_offset: int, payload_size: int, field_offset: int) -> float:
    return frame.decode_float(payload_offset + field_offset) if field_offset + 4 <= payload_size else 0.0


func _payload_u64(frame: PackedByteArray, payload_offset: int, payload_size: int, field_offset: int) -> int:
    if field_offset + 8 > payload_size:
        return 0
    var value := 0
    for index in 8:
        value |= int(frame[payload_offset + field_offset + index]) << (index * 8)
    return value


func _message_id(frame: PackedByteArray) -> int:
    if frame[0] == MAVLINK_STX_V2:
        return int(frame[7]) | (int(frame[8]) << 8) | (int(frame[9]) << 16)
    return int(frame[5])


func _send_command_long(command: int, parameter1: float, parameter7: float = 0.0) -> void:
    var parameters: Array = [parameter1, 0.0, 0.0, 0.0, 0.0, 0.0, parameter7]
    if command == 22:
        # MAV_CMD_NAV_TAKEOFF's latitude/longitude are optional. Zero is a
        # finite coordinate at the Gulf of Guinea, while NaN asks PX4 to use
        # the current global position for a vertical takeoff.
        parameters[4] = NAN
        parameters[5] = NAN
    _send_command_long_parameters(command, parameters)


func _send_simulator_heartbeat() -> void:
    var payload := PackedByteArray()
    payload.append_array(_u32_bytes(0))
    payload.append(6)
    payload.append(5)
    payload.append(0)
    payload.append(0)
    payload.append(3)
    _send_mavlink(payload, MAVLINK_HEARTBEAT, _control_peer)


func _send_command_long_parameters(command: int, parameters: Array) -> void:
    var payload := PackedByteArray()
    for index in 7:
        var value := float(parameters[index]) if index < parameters.size() else 0.0
        payload.append_array(_float_bytes(value))
    payload.append(command & 0xFF)
    payload.append((command >> 8) & 0xFF)
    payload.append(_target_system)
    payload.append(_target_component)
    payload.append(0)
    _last_command_id = command
    _last_command_result = -1
    _pending_command_ids.append(command)
    _trace_qualification_event("outgoing_command_long", _last_poll_time, {
        "command": command,
        "parameters": parameters.duplicate(),
        "target_system": _target_system,
        "target_component": _target_component,
    })
    _send_mavlink(payload, 76, _control_peer)


func _send_mavlink(payload: PackedByteArray, message_id: int, peer) -> void:
    if peer == null:
        return
    var frame := PackedByteArray()
    if message_id == 76:
        frame = PackedByteArray([MAVLINK_STX_V2, payload.size(), 0, 0, _sequence, SIMULATOR_SYSTEM_ID, SIMULATOR_COMPONENT_ID, message_id, 0, 0])
    else:
        frame = PackedByteArray([MAVLINK_STX, payload.size(), _sequence, SIMULATOR_SYSTEM_ID, SIMULATOR_COMPONENT_ID, message_id])
    _sequence = (_sequence + 1) & 0xFF
    frame.append_array(payload)
    var crc := _mavlink_crc(frame.slice(1), _crc_extra(message_id))
    frame.append(crc & 0xFF)
    frame.append((crc >> 8) & 0xFF)
    if _tcp != null and peer == _tcp:
        peer.put_data(frame)
    else:
        peer.put_packet(frame)


func _mavlink_crc_valid(frame: PackedByteArray) -> bool:
    var crc_end := frame.size() - 2
    if frame[0] == MAVLINK_STX_V2 and (int(frame[2]) & 0x01) != 0:
        crc_end -= 13
    var expected := int(frame[crc_end]) | (int(frame[crc_end + 1]) << 8)
    var extra := _crc_extra(_message_id(frame))
    if extra < 0:
        # PX4 emits dialect extensions that are not part of this bridge's
        # command/sensor surface. Their CRC extras are intentionally opaque;
        # ignore those frames after framing and validate every message we
        # actually consume below.
        return true
    return _mavlink_crc(frame.slice(1, crc_end), extra) == expected


func _progress_arm_readiness(now_seconds: float) -> void:
    if _config.get("Transport") == "Fake" or not _arm_requested or _arm_command_sent or _start_time < 0.0:
        return
    if now_seconds - _start_time + 0.000001 < ARM_ESTIMATOR_SETTLE_SECONDS:
        return
    # Do not arm merely because a fixed delay elapsed. PX4 must have emitted
    # two fresh estimator reports proving attitude, horizontal velocity, and
    # local/global position validity. This leaves PX4 preflight and EKF
    # parameters untouched while making an incomplete HIL startup fail closed.
    if not estimator_ready(now_seconds):
        _set_state("failed", false, "PX4 estimator readiness was not proven before arm timeout")
        return
    _send_command_long(400, 1.0)
    _arm_command_sent = true


func _refresh_authority(now_seconds: float, armed: bool) -> void:
    if not armed:
        _set_state("connected", false, "PX4 heartbeat received")
        return
    if state == "stale" and (not _actuator_received_after_arm() or not _actuator_is_fresh(now_seconds)):
        _set_state("stale", false, "PX4 actuator output is stale")
    else:
        var message := "PX4 heartbeat received; awaiting actuator output"
        if _actuator_received_after_arm() and _actuator_is_fresh(now_seconds):
            message = "PX4 heartbeat and actuator output received"
        _set_state("armed", true, message)


func _actuator_received_after_arm() -> bool:
    return _last_actuator_time >= _armed_since and _armed_since >= 0.0


func _uses_source_clock_for_actuator_freshness() -> bool:
    return lockstep_enabled() \
        and _config.get("Transport") != "Fake" \
        and _last_sensor_time >= 0.0 \
        and _last_actuator_simulation_time >= 0.0 \
        and _last_actuator_time_usec >= 0


func _actuator_freshness_age_seconds(now_seconds: float) -> float:
    if _uses_source_clock_for_actuator_freshness():
        # HIL_ACTUATOR_CONTROLS.time_usec is the authoritative wire clock.
        # Canonicalize the locally published fractional seconds to that same
        # integer microsecond domain before comparing: a floating-point value
        # such as 8.716666666... represents the exact 8_716_667us sample.
        var sensor_time_usec := int(round(_last_sensor_time * 1_000_000.0))
        if sensor_time_usec < _last_actuator_time_usec:
            return INF
        return float(sensor_time_usec - _last_actuator_time_usec) / 1_000_000.0
    return maxf(0.0, now_seconds - _last_actuator_time) if _last_actuator_time >= 0.0 else INF


func _actuator_is_fresh(now_seconds: float) -> bool:
    return _actuator_freshness_age_seconds(now_seconds) < float(_config.ActuatorTimeout)


func _trace_qualification_event(kind: String, now_seconds: float, fields: Dictionary = {}) -> void:
    if not _qualification_trace_enabled:
        return
    var entry: Dictionary = {
        "kind": kind,
        "time_seconds": now_seconds,
        "state": state,
        "authority_active": _authority_active,
        "bootstrapped": _start_time >= 0.0 and _last_heartbeat_time >= 0.0,
        "failsafe": state in ["stale", "failed"],
        "arm_requested": _arm_requested,
        "armed_since": _armed_since,
        "hil_mode_requested": _hil_mode_requested,
    }
    for key in fields:
        entry[key] = fields[key]
    _qualification_trace.append(entry)
    if _qualification_trace.size() > QUALIFICATION_TRACE_MAX_ENTRIES:
        _qualification_trace.pop_front()


func _mavlink_crc(data: PackedByteArray, extra: int) -> int:
    var crc := 0xFFFF
    for value in data:
        var byte_value := int(value) ^ (crc & 0xFF)
        byte_value = (byte_value ^ (byte_value << 4)) & 0xFF
        crc = ((crc >> 8) ^ (byte_value << 8) ^ (byte_value << 3) ^ (byte_value >> 4)) & 0xFFFF
    var extra_value := extra ^ (crc & 0xFF)
    extra_value = (extra_value ^ (extra_value << 4)) & 0xFF
    return ((crc >> 8) ^ (extra_value << 8) ^ (extra_value << 3) ^ (extra_value >> 4)) & 0xFFFF


func _float_bytes(value: float) -> PackedByteArray:
    var bytes := PackedByteArray()
    bytes.resize(4)
    bytes.encode_float(0, value)
    return bytes


func _u16_bytes(value: int) -> PackedByteArray:
    return PackedByteArray([value & 0xFF, (value >> 8) & 0xFF])


func _u32_bytes(value: int) -> PackedByteArray:
    return PackedByteArray([value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF])


func _i32_bytes(value: int) -> PackedByteArray:
    return _u32_bytes(value)


func _i16_bytes(value: int) -> PackedByteArray:
    return _u16_bytes(value)


func _u64_bytes(value: int) -> PackedByteArray:
    var bytes := PackedByteArray()
    for index in 8:
        bytes.append((value >> (index * 8)) & 0xFF)
    return bytes


func _crc_extra(message_id: int) -> int:
    match message_id:
        0: return 50
        2: return 137
        24: return 24
        30: return 39
        32: return 185
        76: return 152
        83: return 22
        84: return 143
        85: return 140
        93: return 47
        105: return 93
        107: return 108
        113: return 124
        230: return 163
        231: return 105
        77: return 143
        _: return -1


func _set_state(next_state: String, authority: bool, message: String) -> void:
    var state_before := state
    state = next_state
    _message = message
    if state in ["stale", "failed", "disconnected"]:
        _clear_offboard_target()
    if state_before != state:
        _trace_qualification_event("state_transition", _last_poll_time, {
            "state_before": state_before,
            "message": message,
            "requested_authority": authority,
        })
    _set_authority(authority)


func _update_armed_since(armed: bool, now_seconds: float) -> void:
    if armed:
        if _armed_since < 0.0:
            _armed_since = now_seconds
    else:
        _armed_since = -1.0


func _set_authority(active: bool) -> void:
    if _authority_active == active:
        return
    var authority_before := _authority_active
    _authority_active = active
    _trace_qualification_event("authority_transition", _last_poll_time, {
        "authority_before": authority_before,
        "active": active,
        "callback_fired": _authority_callback.is_valid(),
    })
    if _authority_callback.is_valid():
        _authority_callback.call(active)


func _valid_port(port: int) -> bool:
    return port >= 1 and port <= 65535


func _tcp_connected() -> bool:
    return _tcp != null and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED
