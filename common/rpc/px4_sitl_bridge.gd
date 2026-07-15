class_name Px4SitlBridge
extends RefCounted

const MAVLINK_STX := 0xFE
const MAVLINK_STX_V2 := 0xFD
const MAVLINK_HEARTBEAT := 0
const MAVLINK_COMMAND_ACK := 77
const MAV_CMD_DO_SET_MODE := 176
const MAVLINK_HIL_ACTUATOR_CONTROLS := 93
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
const DEFAULT_TCP_PORT := 4560
const DEFAULT_CONTROL_PORT_LOCAL := 14540
const DEFAULT_CONTROL_PORT_REMOTE := 14580
const DEFAULT_UDP_PORT := 14560

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
var _last_sensor_time := -1.0
var _hil_sensor_reset_sent := false
var _start_time := -1.0
var _armed_since := -1.0
var _arm_requested := false
var _arm_command_sent := false
var _hil_mode_requested := false
var _offboard_requested := false
var _takeoff_pending := false
var _takeoff_altitude := 0.0
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
var _tcp: StreamPeerTCP
var _tcp_server: TCPServer
var _control_peer: PacketPeerUDP
var _tcp_rx_buffer := PackedByteArray()
var _control_rx_buffer := PackedByteArray()


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
    _hil_sensor_reset_sent = false
    _armed_since = -1.0
    _arm_requested = false
    _arm_command_sent = false
    _hil_mode_requested = false
    _offboard_requested = false
    _takeoff_pending = false
    _takeoff_altitude = 0.0
    _last_outbound_heartbeat_time = -1.0
    _actuators = PackedFloat32Array()
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
    var age := now_seconds - _last_heartbeat_time
    var actuator_reference := maxf(_armed_since, _last_actuator_time)
    var actuator_started_after_arm := _last_actuator_time >= _armed_since and _armed_since >= 0.0
    if state == "armed" and actuator_started_after_arm and now_seconds - actuator_reference + 0.000001 >= _config.ActuatorTimeout:
        _actuators = PackedFloat32Array()
        _set_state("stale", false, "PX4 actuator output is stale")
        return
    if age + 0.000001 >= _config.FailureTimeout:
        _set_state("failed", false, "PX4 heartbeat timeout after %.3f seconds" % age)
    elif age > _config.HeartbeatTimeout and state not in ["stale", "failed"]:
        _set_state("stale", false, "PX4 heartbeat is stale after %.3f seconds" % age)


func publish_sensor_snapshot(snapshot: Dictionary, simulation_time_seconds: float) -> void:
    _last_sensor_time = simulation_time_seconds
    if _config.get("Transport") == "Fake" or not _tcp_connected():
        return
    var estimate: Dictionary = snapshot.get("kinematics_estimated", {})
    var imu: Dictionary = snapshot.get("imu_sample", {})
    var gyro: Dictionary = imu.get("gyro", {})
    var accel: Dictionary = imu.get("accel", {})
    var magnetometer: Dictionary = snapshot.get("magnetometer", {})
    var magnetic_field: Dictionary = magnetometer.get("magnetic_field_body", {})
    var barometer_altitude := float(imu.get("barometer_altitude_m", -float(estimate.get("position", {}).get("z_val", 0.0))))
    var accel_x := float(accel.get("x_val", 0.0))
    var accel_y := float(accel.get("y_val", 0.0))
    var accel_z := float(accel.get("z_val", -9.80665))
    var sensor_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    for value in [
        accel_x, accel_y, accel_z,
        float(gyro.get("x_val", 0.0)), float(gyro.get("y_val", 0.0)), float(gyro.get("z_val", 0.0)),
        float(magnetic_field.get("x_val", 0.22)), float(magnetic_field.get("y_val", 0.0)), float(magnetic_field.get("z_val", 0.43)),
        1013.25, 0.0, barometer_altitude, 25.0
    ]:
        sensor_payload.append_array(_float_bytes(value))
    var fields_updated := 0x1FFF
    if not _hil_sensor_reset_sent:
        fields_updated = 1 << 31
        _hil_sensor_reset_sent = true
    sensor_payload.append_array(_u32_bytes(fields_updated))
    sensor_payload.append(0)
    _send_mavlink(sensor_payload, 107, _tcp)

    var system_time_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    system_time_payload.append_array(_u32_bytes(int(round(simulation_time_seconds * 1_000.0))))
    _send_mavlink(system_time_payload, 2, _tcp)

    var velocity: Dictionary = estimate.get("linear_velocity", {})
    var velocity_ned := Vector3(float(velocity.get("x_val", 0.0)), float(velocity.get("y_val", 0.0)), float(velocity.get("z_val", 0.0)))
    var gps: Dictionary = snapshot.get("gps_location", {})
    var gps_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    gps_payload.append_array(_i32_bytes(int(round(float(gps.get("latitude", 0.0)) * 10_000_000.0))))
    gps_payload.append_array(_i32_bytes(int(round(float(gps.get("longitude", 0.0)) * 10_000_000.0))))
    gps_payload.append_array(_i32_bytes(int(round(float(gps.get("altitude", 0.0)) * 1000.0))))
    gps_payload.append_array(_u16_bytes(100))
    gps_payload.append_array(_u16_bytes(100))
    gps_payload.append_array(_u16_bytes(int(round(velocity_ned.length() * 100.0))))
    gps_payload.append_array(_i16_bytes(int(round(float(velocity.get("x_val", 0.0)) * 100.0))))
    gps_payload.append_array(_i16_bytes(int(round(float(velocity.get("y_val", 0.0)) * 100.0))))
    gps_payload.append_array(_i16_bytes(int(round(float(velocity.get("z_val", 0.0)) * 100.0))))
    gps_payload.append_array(_u16_bytes(0))
    gps_payload.append(3)
    gps_payload.append(10)
    gps_payload.append(0)
    gps_payload.append_array(_u16_bytes(0))
    _send_mavlink(gps_payload, 113, _tcp)


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
    if armed:
        # PX4 starts in AUTO_LOITER under HIL. Give EKF2 time to establish a
        # local/global estimate before arming, otherwise its mode fallback can
        # reach flight termination before the first offboard setpoint.
        if not _arm_command_sent and _start_time >= 0.0 and _last_poll_time - _start_time >= ARM_ESTIMATOR_SETTLE_SECONDS:
            _send_command_long(400, 1.0)
            _arm_command_sent = true
    else:
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
    if _config.get("Transport") != "Fake":
        if not _offboard_requested:
            for _attempt in 3:
                _send_position_setpoint(position_ned)
            _send_command_long_parameters(MAV_CMD_DO_SET_MODE, [MAV_MODE_FLAG_CUSTOM_MODE_ENABLED, PX4_CUSTOM_MAIN_MODE_OFFBOARD])
            _offboard_requested = true
        _send_position_setpoint(position_ned)
    return {"ok": true}


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


func actuator_outputs() -> PackedFloat32Array:
    return _actuators


func diagnostics() -> Dictionary:
    return {
        "state": state,
        "message": _message,
        "last_heartbeat_time": _last_heartbeat_time,
        "last_actuator_time": _last_actuator_time,
        "last_sensor_time": _last_sensor_time,
        "authority_active": _authority_active,
        "mission_phase": mission_phase,
        "last_command_id": _last_command_id,
        "last_command_result": _last_command_result,
        "pending_command_ids": _pending_command_ids.duplicate(),
    }


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
            _refresh_authority(now_seconds, armed)
        elif message_id == MAVLINK_HIL_ACTUATOR_CONTROLS:
            if payload_size < 81:
                continue
            # PX4's generated common dialect packs this message as time_usec
            # (8), flags (8), controls[16] (64), and mode (1).
            var armed := (int(frame[payload_offset + 80]) & 0x80) != 0
            _actuators = PackedFloat32Array()
            for index in 4:
                _actuators.append(clampf(frame.decode_float(payload_offset + 16 + index * 4), 0.0, 1.0) if armed else 0.0)
            _last_actuator_time = now_seconds
            if _armed_since >= 0.0:
                _refresh_authority(now_seconds, true)
        elif message_id == MAVLINK_COMMAND_ACK:
            if payload_size < 3:
                continue
            var command := int(frame.decode_u16(payload_offset))
            var result := int(frame[payload_offset + 2])
            if _pending_command_ids.has(command):
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


func _find_mavlink_start(rx_buffer: PackedByteArray) -> int:
    var v1_start := rx_buffer.find(MAVLINK_STX)
    var v2_start := rx_buffer.find(MAVLINK_STX_V2)
    if v1_start < 0:
        return v2_start
    if v2_start < 0:
        return v1_start
    return mini(v1_start, v2_start)


func _message_id(frame: PackedByteArray) -> int:
    if frame[0] == MAVLINK_STX_V2:
        return int(frame[7]) | (int(frame[8]) << 8) | (int(frame[9]) << 16)
    return int(frame[5])


func _send_command_long(command: int, parameter1: float, parameter7: float = 0.0) -> void:
    _send_command_long_parameters(command, [parameter1, 0.0, 0.0, 0.0, 0.0, 0.0, parameter7])


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


func _refresh_authority(now_seconds: float, armed: bool) -> void:
    if not armed:
        _set_state("connected", false, "PX4 heartbeat received")
        return
    if state == "stale" and _last_actuator_time < _armed_since:
        _set_state("stale", false, "PX4 actuator output is stale")
    else:
        var message := "PX4 heartbeat received; awaiting actuator output"
        if _last_actuator_time >= 0.0 and now_seconds - _last_actuator_time < _config.ActuatorTimeout:
            message = "PX4 heartbeat and actuator output received"
        _set_state("armed", true, message)


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
        76: return 152
        84: return 143
        93: return 47
        105: return 93
        107: return 108
        113: return 124
        77: return 143
        _: return -1


func _set_state(next_state: String, authority: bool, message: String) -> void:
    state = next_state
    _message = message
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
    _authority_active = active
    if _authority_callback.is_valid():
        _authority_callback.call(active)


func _valid_port(port: int) -> bool:
    return port >= 1 and port <= 65535


func _tcp_connected() -> bool:
    return _tcp != null and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED
