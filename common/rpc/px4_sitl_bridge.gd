class_name Px4SitlBridge
extends RefCounted

const MAVLINK_STX := 0xFE
const MAVLINK_HEARTBEAT := 0
const MAVLINK_HIL_ACTUATOR_CONTROLS := 93
const DEFAULT_HEARTBEAT_TIMEOUT := 0.5
const DEFAULT_FAILURE_TIMEOUT := 2.0
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
var _last_poll_time := -1.0
var _message := ""
var _pending_heartbeat := -1
var _pending_actuators: Array = []
var _actuators := PackedFloat32Array()
var _tcp: StreamPeerTCP
var _simulator_peer: PacketPeerStream
var _control_peer: PacketPeerUDP
var _rx_buffer := PackedByteArray()


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
    }
    _authority_callback = authority_callback
    var errors: Array[String] = []
    if _config.VehicleType != "PX4Multirotor":
        errors.append("PX4 SITL bridge requires VehicleType PX4Multirotor")
    if _config.UseSerial:
        errors.append("PX4 SITL bridge does not support serial/HITL transport")
    if not _valid_port(_config.TcpPort) or not _valid_port(_config.ControlPortLocal) or not _valid_port(_config.ControlPortRemote) or not _valid_port(_config.UdpPort):
        errors.append("PX4 SITL bridge ports must be in the range 1..65535")
    if _config.HeartbeatTimeout <= 0.0 or _config.FailureTimeout <= _config.HeartbeatTimeout:
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
    if _config.get("Transport") == "Fake":
        state = "starting"
        _message = "waiting for PX4 heartbeat"
        return {"ok": true}
    if not _config.UseTcp:
        state = "failed"
        _message = "PX4 SITL requires UseTcp=true"
        return {"ok": false, "error": _message}
    _tcp = StreamPeerTCP.new()
    var tcp_result := _tcp.connect_to_host(_config.LocalHostIp, _config.TcpPort)
    if tcp_result != OK:
        state = "failed"
        _message = "PX4 simulator TCP connection failed: %s" % tcp_result
        return {"ok": false, "error": _message}
    _simulator_peer = PacketPeerStream.new()
    _simulator_peer.set_stream(_tcp)
    _control_peer = PacketPeerUDP.new()
    var udp_result := _control_peer.bind(_config.ControlPortLocal, _config.ControlIp)
    if udp_result != OK:
        state = "failed"
        _message = "PX4 control UDP bind failed on %s:%d: %s" % [_config.ControlIp, _config.ControlPortLocal, udp_result]
        return {"ok": false, "error": _message}
    _control_peer.set_dest_address(_config.ControlIp, _config.ControlPortRemote)
    state = "starting"
    _message = "waiting for PX4 heartbeat"
    return {"ok": true}


func poll(now_seconds: float) -> void:
    _last_poll_time = now_seconds
    if _config.get("Transport") == "Fake":
        _consume_fake(now_seconds)
    else:
        _poll_real(now_seconds)
    if _last_heartbeat_time < 0.0:
        return
    var age := now_seconds - _last_heartbeat_time
    if age + 0.000001 >= _config.FailureTimeout:
        _set_state("failed", false, "PX4 heartbeat timeout after %.3f seconds" % age)
    elif age > _config.HeartbeatTimeout and state not in ["stale", "failed"]:
        _set_state("stale", false, "PX4 heartbeat is stale after %.3f seconds" % age)


func publish_sensor_snapshot(snapshot: Dictionary, simulation_time_seconds: float) -> void:
    _last_sensor_time = simulation_time_seconds
    if _config.get("Transport") == "Fake" or _simulator_peer == null:
        return
    var estimate: Dictionary = snapshot.get("kinematics_estimated", {})
    var imu: Dictionary = snapshot.get("imu_sample", {})
    var gyro: Dictionary = imu.get("gyro", {})
    var accel: Dictionary = imu.get("accel", {})
    var sensor_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    for value in [
        float(accel.get("x_val", 0.0)), float(accel.get("y_val", 0.0)), float(accel.get("z_val", 0.0)),
        float(gyro.get("x_val", 0.0)), float(gyro.get("y_val", 0.0)), float(gyro.get("z_val", 0.0)),
        0.0, 0.0, 0.0, 1013.25, 0.0, 1013.25, 0.0
    ]:
        sensor_payload.append_array(_float_bytes(value))
    sensor_payload.append_array(_u32_bytes(0x1FFF))
    _send_mavlink(sensor_payload, 107, _simulator_peer)

    var velocity: Dictionary = estimate.get("linear_velocity", {})
    var gps: Dictionary = snapshot.get("gps_location", {})
    var gps_payload := _u64_bytes(int(round(simulation_time_seconds * 1_000_000.0)))
    gps_payload.append(3)
    gps_payload.append_array(_i32_bytes(int(round(float(gps.get("latitude", 0.0)) * 10_000_000.0))))
    gps_payload.append_array(_i32_bytes(int(round(float(gps.get("longitude", 0.0)) * 10_000_000.0))))
    gps_payload.append_array(_i32_bytes(int(round(float(gps.get("altitude", 0.0)) * 1000.0))))
    for value in [100.0, 100.0, 0.0, float(velocity.get("x_val", 0.0) * 100.0), float(velocity.get("y_val", 0.0) * 100.0), float(velocity.get("z_val", 0.0) * 100.0), 0.0]:
        gps_payload.append_array(_u16_bytes(int(round(value))))
    gps_payload.append(10)
    _send_mavlink(gps_payload, 113, _simulator_peer)


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
        else:
            mission_phase = "disarmed"
            _set_state("connected", false, "PX4 disarmed")
        return {"ok": true}
    _send_command_long(400, 1.0 if armed else 0.0)
    return {"ok": true}


func takeoff(position_ned: Vector3) -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "takeoff"
    return setpoint_ned_frd(position_ned, Vector3.ZERO)


func move_to_position(position_ned: Vector3) -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "waypoint"
    return setpoint_ned_frd(position_ned, Vector3.ZERO)


func hover() -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "hover"
    return {"ok": true}


func land() -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    mission_phase = "land"
    return {"ok": true}


func setpoint_ned_frd(position_ned: Vector3, body_rates_frd: Vector3) -> Dictionary:
    if not is_authority_active():
        return {"ok": false, "error": "PX4 authority is inactive"}
    last_setpoint = {
        "position_ned": position_ned,
        "body_rates_frd": body_rates_frd,
    }
    return {"ok": true}


func is_authority_active() -> bool:
    return _authority_active and state in ["connected", "armed"]


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
    }


func stop() -> void:
    if _control_peer != null:
        _control_peer.close()
    _tcp = null
    _simulator_peer = null
    _control_peer = null
    _set_state("disconnected", false, "PX4 transport stopped")


func _consume_fake(now_seconds: float) -> void:
    if _pending_heartbeat >= 0:
        var armed := _pending_heartbeat == 1
        _pending_heartbeat = -1
        _last_heartbeat_time = now_seconds
        _set_state("armed" if armed else "connected", true, "PX4 heartbeat received")
    if not _pending_actuators.is_empty():
        _actuators = PackedFloat32Array(_pending_actuators)
        _pending_actuators.clear()
        _last_actuator_time = now_seconds


func _poll_real(now_seconds: float) -> void:
    if _tcp == null or _simulator_peer == null or _control_peer == null:
        return
    _tcp.poll()
    while _simulator_peer.get_available_packet_count() > 0:
        _consume_mavlink(_simulator_peer.get_packet(), now_seconds)
    while _control_peer.get_available_packet_count() > 0:
        _consume_mavlink(_control_peer.get_packet(), now_seconds)


func _consume_mavlink(packet: PackedByteArray, now_seconds: float) -> void:
    _rx_buffer.append_array(packet)
    while _rx_buffer.size() >= 8:
        var start := _rx_buffer.find(MAVLINK_STX)
        if start < 0:
            _rx_buffer.clear()
            return
        if start > 0:
            _rx_buffer = _rx_buffer.slice(start)
        var payload_size := int(_rx_buffer[1])
        var frame_size := payload_size + 8
        if _rx_buffer.size() < frame_size:
            return
        var frame := _rx_buffer.slice(0, frame_size)
        _rx_buffer = _rx_buffer.slice(frame_size)
        if not _mavlink_crc_valid(frame):
            continue
        var message_id := int(frame[5])
        if message_id == MAVLINK_HEARTBEAT:
            _last_heartbeat_time = now_seconds
            var armed := (int(frame[6 + 6]) & 0x80) != 0
            _set_state("armed" if armed else "connected", true, "PX4 heartbeat received")
        elif message_id == MAVLINK_HIL_ACTUATOR_CONTROLS:
            _actuators = PackedFloat32Array()
            for index in 4:
                _actuators.append(clampf((frame.decode_float(6 + index * 4) + 1.0) * 0.5, 0.0, 1.0))
            _last_actuator_time = now_seconds


func _send_command_long(command: int, parameter1: float) -> void:
    var payload := PackedByteArray()
    for value in [parameter1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]:
        payload.append_array(_float_bytes(value))
    payload.append(command & 0xFF)
    payload.append((command >> 8) & 0xFF)
    payload.append(1)
    payload.append(1)
    _send_mavlink(payload, 76, _control_peer)


func _send_mavlink(payload: PackedByteArray, message_id: int, peer: PacketPeer) -> void:
    if peer == null:
        return
    var frame := PackedByteArray([MAVLINK_STX, payload.size(), 0, 1, 1, message_id])
    frame.append_array(payload)
    var crc := _mavlink_crc(frame.slice(1), _crc_extra(message_id))
    frame.append(crc & 0xFF)
    frame.append((crc >> 8) & 0xFF)
    peer.put_packet(frame)


func _mavlink_crc_valid(frame: PackedByteArray) -> bool:
    var expected := int(frame[frame.size() - 2]) | (int(frame[frame.size() - 1]) << 8)
    return _mavlink_crc(frame.slice(1, frame.size() - 2), _crc_extra(int(frame[5]))) == expected


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


func _u64_bytes(value: int) -> PackedByteArray:
    var bytes := PackedByteArray()
    for index in 8:
        bytes.append((value >> (index * 8)) & 0xFF)
    return bytes


func _crc_extra(message_id: int) -> int:
    match message_id:
        0: return 50
        76: return 152
        93: return 47
        _: return 0


func _set_state(next_state: String, authority: bool, message: String) -> void:
    state = next_state
    _message = message
    _set_authority(authority)


func _set_authority(active: bool) -> void:
    if _authority_active == active:
        return
    _authority_active = active
    if _authority_callback.is_valid():
        _authority_callback.call(active)


func _valid_port(port: int) -> bool:
    return port >= 1 and port <= 65535
