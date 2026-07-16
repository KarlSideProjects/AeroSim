class_name AirSimRpcServer
extends Node

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const AirSimSettings = preload("res://common/rpc/airsim_settings.gd")
const MsgpackCodec = preload("res://common/rpc/msgpack_codec.gd")

const DEFAULT_BIND_ADDRESS := "127.0.0.1"
const DEFAULT_PORT: int = 41451
const MAX_CLIENTS: int = 16
const MAX_CLIENT_BUFFER_BYTES: int = 1_048_576
const MAX_PENDING_ASYNC_TASKS: int = 64
const MAX_COMMAND_DURATION_FRAMES: int = 1_000_000

var bind_address: String = DEFAULT_BIND_ADDRESS
var port: int = DEFAULT_PORT
var _tcp_server := TCPServer.new()
var _running: bool = false
var session := AirSimSession.new()
var settings: Dictionary = {}
var reset_handler: Callable
var _clients: Array = []
var _client_buffers: Dictionary = {}
var _pending_step_responses: Array[Dictionary] = []
var _pending_async_responses: Array[Dictionary] = []
var _cancelled_async_responses: Array[Dictionary] = []
var _active_async_by_vehicle: Dictionary = {}
var _vehicle_names: Array = [""]
var _api_control: Dictionary = {}
var _armed: Dictionary = {}
var _state_provider: Callable
var _command_handler: Callable
var _api_control_handler: Callable
var _arm_handler: Callable
var _cancel_handler: Callable
var _completion_handler: Callable
var _sensor_handler: Callable
var _camera_handler: Callable


func set_session(owner_session: AirSimSession, owner_reset_handler: Callable = Callable()) -> void:
    if _running:
        stop()
    session = owner_session
    reset_handler = owner_reset_handler


func set_vehicle_backend(
        state_provider: Callable,
        command_handler: Callable,
        api_control_handler: Callable = Callable(),
        arm_handler: Callable = Callable(),
        cancel_handler: Callable = Callable(),
        completion_handler: Callable = Callable()) -> void:
    _state_provider = state_provider
    _command_handler = command_handler
    _api_control_handler = api_control_handler
    _arm_handler = arm_handler
    _cancel_handler = cancel_handler
    _completion_handler = completion_handler


func set_sensor_backend(sensor_handler: Callable) -> void:
    _sensor_handler = sensor_handler


func set_camera_backend(camera_handler: Callable) -> void:
    _camera_handler = camera_handler


func validate_bind_address(address: String) -> Dictionary:
    if address != DEFAULT_BIND_ADDRESS:
        return {
            "ok": false,
            "error": "RPC server must bind to 127.0.0.1; public and LAN binds are unsupported",
        }
    return {"ok": true}


func start(address: String = DEFAULT_BIND_ADDRESS, requested_port: int = DEFAULT_PORT) -> Dictionary:
    var address_result := validate_bind_address(address)
    if not address_result.ok:
        return address_result
    if requested_port < 1 or requested_port > 65535:
        return {"ok": false, "error": "RPC port must be an integer from 1 to 65535"}
    if _running:
        stop()
    var listen_error := _tcp_server.listen(requested_port, address)
    if listen_error != OK:
        return {"ok": false, "error": "RPC listener failed: %s" % listen_error}
    bind_address = address
    port = requested_port
    _running = true
    set_process(true)
    return {"ok": true, "bind_address": bind_address, "port": port}


func start_with_settings(raw_settings: Dictionary) -> Dictionary:
    var validation: Dictionary = AirSimSettings.validate(raw_settings)
    if not validation.ok:
        return validation
    settings = validation.settings
    _configure_vehicles(settings)
    if not settings["RpcEnabled"]:
        stop()
        return {"ok": true, "settings": settings, "running": false}
    var result := start(DEFAULT_BIND_ADDRESS, settings["ApiServerPort"])
    result["settings"] = settings
    return result


func stop() -> void:
    _tcp_server.stop()
    for client in _clients:
        client.disconnect_from_host()
    _clients.clear()
    _client_buffers.clear()
    _pending_step_responses.clear()
    _pending_async_responses.clear()
    _cancelled_async_responses.clear()
    _active_async_by_vehicle.clear()
    _running = false
    set_process(false)


func reset_vehicle_control_state() -> void:
    for pending in _pending_async_responses.duplicate():
        _cancel_pending_task(pending, "RPC task canceled by flight lifecycle reset")
    _configure_vehicles(settings)


func is_running() -> bool:
    return _running


func _exit_tree() -> void:
    stop()


func _process(_delta: float) -> void:
    poll()


func poll() -> void:
    if not _running:
        return
    while _tcp_server.is_connection_available():
        var client: StreamPeerTCP = _tcp_server.take_connection()
        if client == null:
            break
        if _clients.size() >= MAX_CLIENTS:
            client.disconnect_from_host()
            continue
        _clients.append(client)
        _client_buffers[client.get_instance_id()] = PackedByteArray()

    for client in _clients.duplicate():
        client.poll()
        var status: int = client.get_status()
        if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
            _remove_client(client)
            continue
        if client.get_available_bytes() > 0:
            var data_result: Array = client.get_data(client.get_available_bytes())
            if data_result[0] != OK:
                _remove_client(client)
                continue
            var client_id: int = client.get_instance_id()
            var buffer: PackedByteArray = _client_buffers[client_id]
            buffer.append_array(data_result[1])
            if buffer.size() > MAX_CLIENT_BUFFER_BYTES:
                _send_response(client, _error_response(null, "RPC request exceeds the maximum frame size"))
                _remove_client(client)
                continue
            _client_buffers[client_id] = buffer
            _process_client_buffer(client)
    _flush_pending_step_responses()


func _process_client_buffer(client: StreamPeerTCP) -> void:
    var client_id: int = client.get_instance_id()
    var buffer: PackedByteArray = _client_buffers[client_id]
    while not buffer.is_empty():
        var decoded: Dictionary = MsgpackCodec.decode(buffer)
        if decoded.incomplete:
            break
        if not decoded.ok:
            _send_response(client, _error_response(null, decoded.error))
            buffer = PackedByteArray()
            break
        var consumed: int = decoded.consumed
        if consumed <= 0:
            _send_response(client, _error_response(null, "RPC decoder consumed no bytes"))
            buffer = PackedByteArray()
            break
        var response: Array
        if typeof(decoded.value) == TYPE_ARRAY:
            response = dispatch(decoded.value)
        else:
            response = _error_response(null, "RPC request must be an array")
        var is_explicit_step: bool = response[2] == null and typeof(decoded.value) == TYPE_ARRAY and decoded.value.size() == 4 and decoded.value[2] in ["simContinueForFrames", "simContinueForTime"]
        var is_async_vehicle_command: bool = response[2] == null and typeof(decoded.value) == TYPE_ARRAY and decoded.value.size() == 4 and _is_async_vehicle_method(decoded.value[2])
        if is_explicit_step:
            _pending_step_responses.append({"client": client, "message_id": response[1]})
        elif is_async_vehicle_command and _pending_async_responses.size() < MAX_PENDING_ASYNC_TASKS:
            _queue_async_response(client, response[1], String(decoded.value[2]), decoded.value[3])
        elif is_async_vehicle_command:
            if not _send_response(client, _error_response(response[1], "too many pending RPC tasks")):
                _remove_client(client)
                return
        elif not _send_response(client, response):
            _remove_client(client)
            return
        buffer = buffer.slice(consumed)
    _client_buffers[client_id] = buffer


func _send_response(client: StreamPeerTCP, response: Array) -> bool:
    return client.put_data(MsgpackCodec.encode(response)) == OK


func _remove_client(client: StreamPeerTCP) -> void:
    client.disconnect_from_host()
    _clients.erase(client)
    _client_buffers.erase(client.get_instance_id())
    for pending in _pending_step_responses.duplicate():
        if pending["client"] == client:
            _pending_step_responses.erase(pending)
    for pending in _pending_async_responses.duplicate():
        if pending["client"] == client:
            _cancel_pending_task(pending, "RPC client disconnected")
    for pending in _cancelled_async_responses.duplicate():
        if pending["client"] == client:
            _cancelled_async_responses.erase(pending)


func _queue_async_response(client: StreamPeerTCP, message_id, method: String, params: Array) -> void:
    var vehicle_name := _async_vehicle_name(params)
    var previous = _active_async_by_vehicle.get(vehicle_name)
    if previous is Dictionary:
        _cancel_pending_task(previous, "RPC task superseded", false)
    var pending := {
        "client": client,
        "message_id": message_id,
        "vehicle_name": vehicle_name,
        "complete_frame": session.frame_index + _async_command_frames(method, params),
        "timeout_frame": session.frame_index + _async_timeout_frames(method, params),
        "result": true,
    }
    _pending_async_responses.append(pending)
    _active_async_by_vehicle[vehicle_name] = pending


func _cancel_pending_task(pending: Dictionary, reason: String, notify_backend: bool = true) -> void:
    _pending_async_responses.erase(pending)
    if _active_async_by_vehicle.get(String(pending["vehicle_name"])) == pending:
        _active_async_by_vehicle.erase(String(pending["vehicle_name"]))
    if notify_backend and _cancel_handler.is_valid():
        _cancel_handler.call(String(pending["vehicle_name"]))
    _cancelled_async_responses.append({
        "client": pending["client"],
        "message_id": pending["message_id"],
        "error": reason,
    })


func _flush_pending_step_responses() -> void:
    if session.is_explicit_step_active():
        return
    for pending in _pending_step_responses.duplicate():
        var client: StreamPeerTCP = pending["client"]
        _pending_step_responses.erase(pending)
        if not _clients.has(client):
            continue
        if not _send_response(client, _success_response(pending["message_id"], null)):
            _remove_client(client)
    _flush_pending_async_responses()


func _flush_pending_async_responses() -> void:
    for cancelled in _cancelled_async_responses.duplicate():
        _cancelled_async_responses.erase(cancelled)
        var cancelled_client: StreamPeerTCP = cancelled["client"]
        if not _clients.has(cancelled_client):
            continue
        if not _send_response(cancelled_client, _success_response(cancelled["message_id"], false)):
            _remove_client(cancelled_client)
    for pending in _pending_async_responses.duplicate():
        var complete := session.frame_index >= int(pending["complete_frame"])
        if _completion_handler.is_valid():
            complete = complete and bool(_completion_handler.call(String(pending["vehicle_name"])))
        if not complete:
            if session.frame_index < int(pending["timeout_frame"]):
                continue
            _pending_async_responses.erase(pending)
            if _cancel_handler.is_valid():
                _cancel_handler.call(String(pending["vehicle_name"]))
            var timeout_client: StreamPeerTCP = pending["client"]
            if not _clients.has(timeout_client):
                continue
            if _active_async_by_vehicle.get(String(pending["vehicle_name"])) == pending:
                _active_async_by_vehicle.erase(String(pending["vehicle_name"]))
            if not _send_response(timeout_client, _success_response(pending["message_id"], false)):
                _remove_client(timeout_client)
            continue
        _pending_async_responses.erase(pending)
        if _active_async_by_vehicle.get(String(pending["vehicle_name"])) == pending:
            _active_async_by_vehicle.erase(String(pending["vehicle_name"]))
        var client: StreamPeerTCP = pending["client"]
        if not _clients.has(client):
            continue
        if not _send_response(client, _success_response(pending["message_id"], pending["result"])):
            _remove_client(client)


func _is_async_vehicle_method(method: Variant) -> bool:
    return typeof(method) == TYPE_STRING and method in [
        "takeoff", "land", "hover", "goHome", "moveToPosition", "moveOnPath",
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame",
        "moveByVelocityZBodyFrame", "rotateToYaw", "rotateByYawRate",
        "moveByAngleRatesThrottle",
    ]


func _async_vehicle_name(params: Array) -> String:
    if params.is_empty() or typeof(params[params.size() - 1]) != TYPE_STRING:
        return ""
    var name := String(params[params.size() - 1])
    if name.is_empty() and _vehicle_names.size() == 1:
        return String(_vehicle_names[0])
    return name


func _async_command_frames(method: String, params: Array) -> int:
    var duration_index := -1
    match method:
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame":
            duration_index = 3
        "rotateByYawRate", "moveByAngleRatesThrottle":
            duration_index = 1 if method == "rotateByYawRate" else 4
    if duration_index >= 0 and duration_index < params.size() and _is_numeric(params[duration_index]):
        return mini(MAX_COMMAND_DURATION_FRAMES, maxi(1, ceili(float(params[duration_index]) * float(session.physics_hz))))
    return 1


func _async_timeout_frames(method: String, params: Array) -> int:
    var timeout_index := -1
    match method:
        "takeoff", "land", "goHome":
            timeout_index = 0
        "moveToPosition":
            timeout_index = 4
        "moveOnPath":
            timeout_index = 2
        "rotateToYaw":
            timeout_index = 1
    if timeout_index >= 0 and timeout_index < params.size() and _is_numeric(params[timeout_index]):
        return maxi(0, ceili(minf(float(params[timeout_index]) * float(session.physics_hz), 1_000_000_000.0)))
    return 1_000_000_000


func dispatch(request: Array) -> Array:
    if request.size() != 4:
        return _error_response(null, "RPC request must contain four fields")
    if request[0] != 0:
        return _error_response(request[1], "unsupported RPC request type")

    var message_id = request[1]
    var method = request[2]
    var params = request[3]
    if typeof(method) != TYPE_STRING or typeof(params) != TYPE_ARRAY:
        return _error_response(message_id, "RPC method and params have invalid types")

    match method:
        "ping":
            return _success_response(message_id, true)
        "simPause":
            if params.size() != 1 or typeof(params[0]) != TYPE_BOOL:
                return _error_response(message_id, "simPause expects one boolean parameter")
            session.set_paused(params[0])
            return _success_response(message_id, null)
        "simIsPaused":
            if not params.is_empty():
                return _error_response(message_id, "simIsPaused expects no parameters")
            return _success_response(message_id, session.is_paused())
        "simContinueForFrames":
            if params.size() != 1 or typeof(params[0]) != TYPE_INT:
                return _error_response(message_id, "simContinueForFrames expects one integer parameter")
            return _session_response(message_id, session.continue_for_frames(params[0]))
        "simContinueForTime":
            if params.size() != 1 or (typeof(params[0]) != TYPE_FLOAT and typeof(params[0]) != TYPE_INT):
                return _error_response(message_id, "simContinueForTime expects one numeric parameter")
            return _session_response(message_id, session.continue_for_time(float(params[0])))
        "reset":
            if not params.is_empty():
                return _error_response(message_id, "reset expects no parameters")
            session.reset()
            if reset_handler.is_valid():
                reset_handler.call()
            reset_vehicle_control_state()
            return _success_response(message_id, null)
        "getServerVersion":
            if not params.is_empty():
                return _error_response(message_id, "getServerVersion expects no parameters")
            return _success_response(message_id, 1)
        "getMinRequiredClientVersion":
            if not params.is_empty():
                return _error_response(message_id, "getMinRequiredClientVersion expects no parameters")
            return _success_response(message_id, 1)
        "getSettingsString":
            if not params.is_empty():
                return _error_response(message_id, "getSettingsString expects no parameters")
            return _success_response(message_id, JSON.stringify(settings))
        "listVehicles":
            if not params.is_empty():
                return _error_response(message_id, "listVehicles expects no parameters")
            return _success_response(message_id, _vehicle_names.duplicate())
        "enableApiControl":
            return _dispatch_enable_api_control(message_id, params)
        "isApiControlEnabled":
            return _dispatch_is_api_control_enabled(message_id, params)
        "armDisarm":
            return _dispatch_arm_disarm(message_id, params)
        "getMultirotorState":
            return _dispatch_multirotor_state(message_id, params)
        "getHomeGeoPoint":
            return _dispatch_home_geo_point(message_id, params)
        "simGetVehiclePose":
            return _dispatch_vehicle_pose(message_id, params)
        "simGetCollisionInfo":
            return _dispatch_collision_info(message_id, params)
        "simGetImages":
            return _dispatch_images(message_id, params)
        "getImuData":
            return _dispatch_sensor(message_id, params, 2, "getImuData")
        "getGpsData":
            return _dispatch_sensor(message_id, params, 3, "getGpsData")
        "getMagnetometerData":
            return _dispatch_sensor(message_id, params, 4, "getMagnetometerData")
        "getBarometerData":
            return _dispatch_sensor(message_id, params, 1, "getBarometerData")
        "getLidarData":
            return _dispatch_sensor(message_id, params, 6, "getLidarData")
        "moveByMotorPWMs":
            return _error_response(message_id, "direct per-motor PWM is unsupported at the flight-controller boundary")
        "cancelLastTask":
            return _dispatch_cancel_last_task(message_id, params)
        "takeoff", "land", "hover", "goHome", "moveToPosition", "moveOnPath", "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateToYaw", "rotateByYawRate", "moveByAngleRatesThrottle":
            return _dispatch_vehicle_command(message_id, method, params)
        _:
            return _error_response(message_id, "unsupported RPC method: %s" % method)


func _configure_vehicles(new_settings: Dictionary) -> void:
    _vehicle_names = [""]
    var configured = new_settings.get("Vehicles", {})
    if typeof(configured) == TYPE_DICTIONARY and not configured.is_empty():
        _vehicle_names.clear()
        for vehicle_name in configured.keys():
            _vehicle_names.append(String(vehicle_name))
    _api_control.clear()
    _armed.clear()
    for vehicle_name in _vehicle_names:
        _api_control[vehicle_name] = false
        _armed[vehicle_name] = false


func _resolve_vehicle(message_id, requested_name: Variant) -> Dictionary:
    if typeof(requested_name) != TYPE_STRING:
        return {"ok": false, "response": _error_response(message_id, "vehicle_name must be a string")}
    var name := String(requested_name)
    if name.is_empty() and _vehicle_names.size() == 1:
        name = String(_vehicle_names[0])
        if name.is_empty():
            return {"ok": true, "name": name}
    var validation := AirSimSettings.validate_vehicle_name(name, _vehicle_names)
    if not validation.ok:
        return {"ok": false, "response": _error_response(message_id, validation.error)}
    return {"ok": true, "name": name}


func _dispatch_enable_api_control(message_id, params: Array) -> Array:
    if params.size() != 2 or typeof(params[0]) != TYPE_BOOL:
        return _error_response(message_id, "enableApiControl expects a boolean and vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[1])
    if not vehicle.ok:
        return vehicle.response
    var name: String = vehicle.name
    if _api_control_handler.is_valid():
        var result = _api_control_handler.call(bool(params[0]), name)
        if typeof(result) == TYPE_DICTIONARY and not bool(result.get("ok", false)):
            return _error_response(message_id, String(result.get("error", "API control rejected")))
    _api_control[name] = params[0]
    if not params[0]:
        _cancel_vehicle_tasks(name, "RPC task canceled by disabling API control")
        _armed[name] = false
    return _success_response(message_id, null)


func _dispatch_is_api_control_enabled(message_id, params: Array) -> Array:
    if params.size() != 1:
        return _error_response(message_id, "isApiControlEnabled expects vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[0])
    if not vehicle.ok:
        return vehicle.response
    return _success_response(message_id, bool(_api_control[vehicle.name]))


func _dispatch_arm_disarm(message_id, params: Array) -> Array:
    if params.size() != 2 or typeof(params[0]) != TYPE_BOOL:
        return _error_response(message_id, "armDisarm expects a boolean and vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[1])
    if not vehicle.ok:
        return vehicle.response
    var name: String = vehicle.name
    if params[0] and not bool(_api_control[name]):
        return _success_response(message_id, false)
    if _arm_handler.is_valid():
        var result = _arm_handler.call(bool(params[0]), name)
        if typeof(result) == TYPE_DICTIONARY:
            if not bool(result.get("ok", false)):
                return _error_response(message_id, String(result.get("error", "arm state rejected")))
            if result.has("armed"):
                _armed[name] = bool(result["armed"])
                if not params[0]:
                    _cancel_vehicle_tasks(name, "RPC task canceled by disarm")
                return _success_response(message_id, bool(result["armed"]))
        elif not bool(result):
            return _success_response(message_id, false)
    if not params[0]:
        _cancel_vehicle_tasks(name, "RPC task canceled by disarm")
    _armed[name] = params[0]
    return _success_response(message_id, true)


func _dispatch_multirotor_state(message_id, params: Array) -> Array:
    if params.size() != 1:
        return _error_response(message_id, "getMultirotorState expects vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[0])
    if not vehicle.ok:
        return vehicle.response
    if not _state_provider.is_valid():
        return _error_response(message_id, "vehicle state backend is unavailable")
    var state_result = _state_provider.call(vehicle.name)
    if typeof(state_result) != TYPE_DICTIONARY or not bool(state_result.get("ok", false)):
        return _error_response(message_id, String(state_result.get("error", "vehicle state backend rejected the request")) if typeof(state_result) == TYPE_DICTIONARY else "vehicle state backend returned an invalid snapshot")
    var state: Dictionary = state_result["state"].duplicate(true)
    state.erase("imu_sample")
    state["timestamp"] = int(round(session.simulation_time_seconds * 1_000_000_000.0))
    return _success_response(message_id, state)


func _dispatch_home_geo_point(message_id, params: Array) -> Array:
    if params.size() != 1:
        return _error_response(message_id, "getHomeGeoPoint expects vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[0])
    if not vehicle.ok:
        return vehicle.response
    var origin: Dictionary = settings.get("OriginGeopoint", {})
    return _success_response(message_id, {
        "latitude": float(origin.get("Latitude", 0.0)),
        "longitude": float(origin.get("Longitude", 0.0)),
        "altitude": float(origin.get("Altitude", 0.0)),
    })


func _dispatch_vehicle_pose(message_id, params: Array) -> Array:
    if params.size() != 1:
        return _error_response(message_id, "simGetVehiclePose expects vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[0])
    if not vehicle.ok:
        return vehicle.response
    var state_result := _state_for_vehicle(vehicle.name)
    if not state_result.ok:
        return _error_response(message_id, state_result.error)
    var kinematics: Dictionary = state_result.state["kinematics_estimated"]
    return _success_response(message_id, {
        "position": kinematics["position"].duplicate(true),
        "orientation": kinematics["orientation"].duplicate(true),
    })


func _dispatch_collision_info(message_id, params: Array) -> Array:
    if params.size() != 1:
        return _error_response(message_id, "simGetCollisionInfo expects vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[0])
    if not vehicle.ok:
        return vehicle.response
    var state_result := _state_for_vehicle(vehicle.name)
    if not state_result.ok:
        return _error_response(message_id, state_result.error)
    return _success_response(message_id, state_result.state["collision"].duplicate(true))


func _dispatch_sensor(message_id, params: Array, sensor_type: int, method: String) -> Array:
    if params.size() != 2 or typeof(params[0]) != TYPE_STRING or typeof(params[1]) != TYPE_STRING:
        return _error_response(message_id, "%s expects sensor_name and vehicle_name" % method)
    var vehicle := _resolve_vehicle(message_id, params[1])
    if not vehicle.ok:
        return vehicle.response
    if not _sensor_handler.is_valid():
        return _error_response(message_id, "sensor backend is unavailable")
    var result = _sensor_handler.call(sensor_type, String(params[0]), String(vehicle.name))
    if typeof(result) != TYPE_DICTIONARY or not bool(result.get("ok", false)):
        return _error_response(message_id, String(result.get("error", "sensor backend rejected the request")) if typeof(result) == TYPE_DICTIONARY else "sensor backend returned an invalid result")
    var public_sensor: Dictionary = result["sensor"].duplicate(true)
    public_sensor.erase("aerosim_identity")
    return _success_response(message_id, public_sensor)


func _dispatch_images(message_id, params: Array) -> Array:
    if params.size() == 3 and typeof(params[0]) != TYPE_ARRAY:
        return _error_response(message_id, "simGetImages requests must be an array")
    if params.size() != 3 or typeof(params[1]) != TYPE_STRING or typeof(params[2]) != TYPE_BOOL:
        return _error_response(message_id, "simGetImages expects requests, vehicle_name, and external")
    if params[2]:
        return _error_response(message_id, "simGetImages external cameras are unsupported")
    var vehicle := _resolve_vehicle(message_id, params[1])
    if not vehicle.ok:
        return vehicle.response
    if not _camera_handler.is_valid():
        return _error_response(message_id, "camera backend is unavailable")
    var result = _camera_handler.call(params[0], String(vehicle.name), false)
    if typeof(result) != TYPE_DICTIONARY or not bool(result.get("ok", false)):
        return _error_response(message_id, String(result.get("error", "camera backend rejected the request")) if typeof(result) == TYPE_DICTIONARY else "camera backend returned an invalid result")
    var responses = result.get("responses", [])
    if typeof(responses) != TYPE_ARRAY:
        return _error_response(message_id, "camera backend returned invalid image responses")
    var public_responses: Array = []
    for response in responses:
        var public_response: Dictionary = response.duplicate(true)
        public_response.erase("aerosim_identity")
        public_responses.append(public_response)
    return _success_response(message_id, public_responses)


func _state_for_vehicle(name: String) -> Dictionary:
    if not _state_provider.is_valid():
        return {"ok": false, "error": "vehicle state backend is unavailable"}
    var result = _state_provider.call(name)
    if typeof(result) != TYPE_DICTIONARY or not bool(result.get("ok", false)):
        return {"ok": false, "error": String(result.get("error", "vehicle state backend rejected the request")) if typeof(result) == TYPE_DICTIONARY else "vehicle state backend returned an invalid snapshot"}
    return {"ok": true, "state": result["state"].duplicate(true)}


func _dispatch_cancel_last_task(message_id, params: Array) -> Array:
    if params.size() != 1:
        return _error_response(message_id, "cancelLastTask expects vehicle_name")
    var vehicle := _resolve_vehicle(message_id, params[0])
    if not vehicle.ok:
        return vehicle.response
    _cancel_vehicle_tasks(String(vehicle.name), "RPC task canceled")
    return _success_response(message_id, null)


func _cancel_vehicle_tasks(vehicle_name: String, reason: String) -> void:
    var canceled := false
    for pending in _pending_async_responses.duplicate():
        if String(pending["vehicle_name"]) == vehicle_name:
            _cancel_pending_task(pending, reason)
            canceled = true
    if not canceled and _cancel_handler.is_valid():
        _cancel_handler.call(vehicle_name)


func _dispatch_vehicle_command(message_id, method: String, params: Array) -> Array:
    var vehicle_name_index := params.size() - 1
    if vehicle_name_index < 0:
        return _error_response(message_id, "%s requires vehicle_name" % method)
    var vehicle := _resolve_vehicle(message_id, params[vehicle_name_index])
    if not vehicle.ok:
        return vehicle.response
    var name: String = vehicle.name
    if not bool(_api_control[name]):
        return _error_response(message_id, "%s requires API control" % method)
    if not bool(_armed[name]):
        return _error_response(message_id, "%s requires an armed vehicle" % method)

    match method:
        "takeoff", "land", "goHome":
            if params.size() != 2 or not _is_numeric(params[0]):
                return _error_response(message_id, "%s expects timeout_sec and vehicle_name" % method)
            if float(params[0]) < 0.0:
                return _error_response(message_id, "%s timeout_sec must not be negative" % method)
        "hover":
            if params.size() != 1:
                return _error_response(message_id, "hover expects vehicle_name")
        "moveToPosition":
            if params.size() != 10 or not _is_numeric(params[0]) or not _is_numeric(params[1]) or not _is_numeric(params[2]) or not _is_numeric(params[3]) or not _is_numeric(params[4]):
                return _error_response(message_id, "moveToPosition expects the AirSim position command parameters")
            if float(params[3]) <= 0.0:
                return _error_response(message_id, "moveToPosition velocity must be positive")
            if float(params[4]) < 0.0:
                return _error_response(message_id, "moveToPosition timeout_sec must not be negative")
        "moveOnPath":
            if params.size() != 8 or typeof(params[0]) != TYPE_ARRAY or not _is_numeric(params[1]) or not _is_numeric(params[2]):
                return _error_response(message_id, "moveOnPath expects the AirSim path command parameters")
            var path: Array = params[0]
            if path.is_empty() or typeof(path[path.size() - 1]) != TYPE_DICTIONARY:
                return _error_response(message_id, "moveOnPath requires a non-empty Vector3r path")
            if float(params[2]) < 0.0:
                return _error_response(message_id, "moveOnPath timeout_sec must not be negative")
            if float(params[1]) <= 0.0:
                return _error_response(message_id, "moveOnPath velocity must be positive")
            for point in path:
                if typeof(point) != TYPE_DICTIONARY or not point.has("x_val") or not point.has("y_val") or not point.has("z_val") or not _is_numeric(point["x_val"]) or not _is_numeric(point["y_val"]) or not _is_numeric(point["z_val"]):
                    return _error_response(message_id, "moveOnPath path points must be Vector3r payloads")
        "moveByVelocity":
            if params.size() != 7 or not _is_numeric(params[0]) or not _is_numeric(params[1]) or not _is_numeric(params[2]) or not _is_numeric(params[3]):
                return _error_response(message_id, "moveByVelocity expects the AirSim velocity command parameters")
            if float(params[3]) < 0.0:
                return _error_response(message_id, "moveByVelocity duration must not be negative")
        "moveByVelocityZ":
            if params.size() != 7 or not _is_numeric(params[0]) or not _is_numeric(params[1]) or not _is_numeric(params[2]) or not _is_numeric(params[3]):
                return _error_response(message_id, "moveByVelocityZ expects the AirSim velocity command parameters")
            if float(params[3]) < 0.0:
                return _error_response(message_id, "moveByVelocityZ duration must not be negative")
        "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame":
            if params.size() != 7 or not _is_numeric(params[0]) or not _is_numeric(params[1]) or not _is_numeric(params[2]) or not _is_numeric(params[3]):
                return _error_response(message_id, "%s expects the AirSim body-frame velocity command parameters" % method)
            if float(params[3]) < 0.0:
                return _error_response(message_id, "%s duration must not be negative" % method)
        "rotateToYaw":
            if params.size() != 4 or not _is_numeric(params[0]) or not _is_numeric(params[1]) or not _is_numeric(params[2]):
                return _error_response(message_id, "rotateToYaw expects yaw, timeout_sec, margin, and vehicle_name")
            if float(params[1]) < 0.0 or float(params[2]) < 0.0:
                return _error_response(message_id, "rotateToYaw timeout_sec and margin must not be negative")
        "rotateByYawRate":
            if params.size() != 3 or not _is_numeric(params[0]) or not _is_numeric(params[1]):
                return _error_response(message_id, "rotateByYawRate expects yaw_rate, duration, and vehicle_name")
            if float(params[1]) < 0.0:
                return _error_response(message_id, "rotateByYawRate duration must not be negative")
        "moveByAngleRatesThrottle":
            if params.size() != 6 or not _is_numeric(params[0]) or not _is_numeric(params[1]) or not _is_numeric(params[2]) or not _is_numeric(params[3]) or not _is_numeric(params[4]):
                return _error_response(message_id, "moveByAngleRatesThrottle expects the AirSim body-rate command parameters")
            if float(params[3]) < 0.0 or float(params[3]) > 1.0:
                return _error_response(message_id, "moveByAngleRatesThrottle throttle must be from 0 to 1")
            if float(params[4]) < 0.0:
                return _error_response(message_id, "moveByAngleRatesThrottle duration must not be negative")
        _:
            return _error_response(message_id, "unsupported vehicle command: %s" % method)
    var options_result := _validate_motion_options(method, params)
    if not options_result.ok:
        return _error_response(message_id, options_result.error)
    if not _command_handler.is_valid():
        return _error_response(message_id, "vehicle command backend is unavailable")
    var result = _command_handler.call(method, params, name)
    if typeof(result) != TYPE_DICTIONARY or not bool(result.get("ok", false)):
        return _error_response(message_id, String(result.get("error", "vehicle command backend rejected the request")) if typeof(result) == TYPE_DICTIONARY else "vehicle command backend returned an invalid result")
    return _success_response(message_id, null)


func _is_numeric(value: Variant) -> bool:
    return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value))


func _validate_motion_options(method: String, params: Array) -> Dictionary:
    var drivetrain_index := -1
    var yaw_index := -1
    var lookahead_index := -1
    var adaptive_index := -1
    match method:
        "moveToPosition":
            drivetrain_index = 5
            yaw_index = 6
            lookahead_index = 7
            adaptive_index = 8
        "moveOnPath":
            drivetrain_index = 3
            yaw_index = 4
            lookahead_index = 5
            adaptive_index = 6
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame":
            drivetrain_index = 4
            yaw_index = 5
    if drivetrain_index >= 0 and (typeof(params[drivetrain_index]) != TYPE_INT or int(params[drivetrain_index]) != 0):
        return {"ok": false, "error": "%s only supports MaxDegreeOfFreedom drivetrain (0); ForwardOnly is unsupported" % method}
    if yaw_index >= 0:
        var yaw = params[yaw_index]
        if typeof(yaw) != TYPE_DICTIONARY or typeof(yaw.get("is_rate")) != TYPE_BOOL or not _is_numeric(yaw.get("yaw_or_rate")):
            return {"ok": false, "error": "%s yaw_mode must contain is_rate and numeric yaw_or_rate" % method}
    for index in [lookahead_index, adaptive_index]:
        if index >= 0 and not _is_numeric(params[index]):
            return {"ok": false, "error": "%s lookahead values must be numeric" % method}
    return {"ok": true}


func _session_response(message_id, result: Dictionary) -> Array:
    if result.ok:
        return _success_response(message_id, null)
    return _error_response(message_id, result.error)


func _success_response(message_id, result) -> Array:
    return [1, message_id, null, result]


func _error_response(message_id, message: String) -> Array:
    return [1, message_id, message, null]
