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
const MAX_PENDING_RESET_WAITERS: int = 64
const RESET_RESPONSE_TIMEOUT_MS: int = 10_000
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
var _client_epochs: Dictionary = {}
var _next_client_epoch := 1
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
var _scene_object_handler: Callable
var _environment_handler: Callable
var _replay_simulation_handler: Callable
var _replay_async_handler: Callable
var _reset_environment_replay_handler: Callable
var _publication_error_handler: Callable
var _reset_start_handler: Callable
var _reset_status_handler: Callable
var _reset_abort_handler: Callable
var _pending_reset_waiters: Array[Dictionary] = []
var _active_reset_generation := 0


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


func set_scene_environment_backend(scene_object_handler: Callable, environment_handler: Callable) -> void:
    _scene_object_handler = scene_object_handler
    _environment_handler = environment_handler


func set_replay_handlers(simulation_handler: Callable, async_handler: Callable, reset_environment_handler: Callable = Callable()) -> void:
    _replay_simulation_handler = simulation_handler
    _replay_async_handler = async_handler
    _reset_environment_replay_handler = reset_environment_handler


func set_publication_error_handler(handler: Callable) -> void:
    _publication_error_handler = handler


func set_reset_lifecycle_handlers(start_handler: Callable, status_handler: Callable, abort_handler: Callable) -> void:
    _reset_start_handler = start_handler
    _reset_status_handler = status_handler
    _reset_abort_handler = abort_handler


func cancel_pending_async_tasks(reason: String = "RPC session terminated") -> void:
    for pending in _pending_async_responses.duplicate():
        _cancel_pending_task(pending, reason)


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
    _client_epochs.clear()
    _pending_step_responses.clear()
    _pending_async_responses.clear()
    _cancelled_async_responses.clear()
    _active_async_by_vehicle.clear()
    _pending_reset_waiters.clear()
    _active_reset_generation = 0
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
    # A physical reset can outlive every transport waiter.  Reconcile it
    # before accepting new requests so a later reset never attaches to a
    # generation that has already committed or failed.
    _flush_pending_reset_waiters()
    while _tcp_server.is_connection_available():
        var client: StreamPeerTCP = _tcp_server.take_connection()
        if client == null:
            break
        if _clients.size() >= MAX_CLIENTS:
            client.disconnect_from_host()
            continue
        _clients.append(client)
        _client_buffers[client.get_instance_id()] = PackedByteArray()
        _client_epochs[client.get_instance_id()] = _next_client_epoch
        _next_client_epoch += 1

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
        if typeof(decoded.value) != TYPE_ARRAY:
            response = _error_response(null, "RPC request must be an array")
        else:
            var validation := _validate_request(decoded.value)
            if not bool(validation["ok"]):
                response = _error_response(validation["message_id"], String(validation["error"]))
            elif decoded.value[2] == "reset" and _reset_start_handler.is_valid():
                _queue_reset_waiter(client, decoded.value)
                buffer = buffer.slice(consumed)
                continue
            else:
                response = dispatch(decoded.value)
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
    _client_epochs.erase(client.get_instance_id())
    for pending in _pending_step_responses.duplicate():
        if pending["client"] == client:
            _pending_step_responses.erase(pending)
    for pending in _pending_async_responses.duplicate():
        if pending["client"] == client:
            _cancel_pending_task(pending, "RPC client disconnected")
    for waiter in _pending_reset_waiters.duplicate():
        if waiter["client"] == client:
            _pending_reset_waiters.erase(waiter)
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
        "command_id": "%s" % message_id,
        "method": method,
        "vehicle_name": vehicle_name,
        "complete_frame": session.frame_index + _async_command_frames(method, params),
        "timeout_frame": session.frame_index + _async_timeout_frames(method, params),
        "result": true,
    }
    _pending_async_responses.append(pending)
    _active_async_by_vehicle[vehicle_name] = pending
    if _replay_async_handler.is_valid():
        _replay_async_handler.call(session.simulation_time_seconds, vehicle_name, "%s" % message_id, method, 0)
        _replay_async_handler.call(session.simulation_time_seconds, vehicle_name, "%s" % message_id, method, 1)


func _cancel_pending_task(pending: Dictionary, reason: String, notify_backend: bool = true) -> void:
    _pending_async_responses.erase(pending)
    if _active_async_by_vehicle.get(String(pending["vehicle_name"])) == pending:
        _active_async_by_vehicle.erase(String(pending["vehicle_name"]))
    if notify_backend and _cancel_handler.is_valid():
        _cancel_handler.call(String(pending["vehicle_name"]))
    if _replay_async_handler.is_valid():
        _replay_async_handler.call(session.simulation_time_seconds, String(pending["vehicle_name"]),
            "%s" % pending.get("command_id", pending["message_id"]), String(pending.get("method", "")), 3)
    _cancelled_async_responses.append({
        "client": pending["client"],
        "message_id": pending["message_id"],
        "error": reason,
    })


func _flush_pending_step_responses() -> void:
    if session.is_explicit_step_active():
        _flush_pending_reset_waiters()
        return
    for pending in _pending_step_responses.duplicate():
        var client: StreamPeerTCP = pending["client"]
        _pending_step_responses.erase(pending)
        if not _clients.has(client):
            continue
        if not _send_response(client, _success_response(pending["message_id"], null)):
            _remove_client(client)
    _flush_pending_async_responses()
    _flush_pending_reset_waiters()


func _queue_reset_waiter(client: StreamPeerTCP, request: Array) -> void:
    var message_id = request[1]
    if typeof(request[3]) != TYPE_ARRAY or not request[3].is_empty():
        _send_or_remove(client, _error_response(message_id, "reset expects no parameters"))
        return
    var client_epoch := int(_client_epochs.get(client.get_instance_id(), -1))
    for waiter in _pending_reset_waiters:
        if int(waiter["client_epoch"]) == client_epoch and waiter["message_id"] == message_id:
            return
    if _pending_reset_waiters.size() >= MAX_PENDING_RESET_WAITERS:
        _send_or_remove(client, _error_response(message_id, "too many pending reset requests"))
        return
    var generation := _active_reset_generation
    if generation == 0:
        var result = _reset_start_handler.call()
        if typeof(result) != TYPE_DICTIONARY or not bool(result.get("ok", false)):
            _send_or_remove(client, _error_response(message_id, String(result.get("error", "reset rejected")) if typeof(result) == TYPE_DICTIONARY else "reset handler returned an invalid result"))
            return
        generation = int(result.get("generation", 0))
        if generation <= 0:
            _send_or_remove(client, _error_response(message_id, "reset handler returned an invalid generation"))
            return
        _active_reset_generation = generation
    # Concurrent AirSim reset calls join the one active physical generation;
    # every retained request receives that generation's final outcome.
    _pending_reset_waiters.append({
        "client": client,
        "client_epoch": client_epoch,
        "message_id": message_id,
        "generation": generation,
        "deadline_ms": Time.get_ticks_msec() + RESET_RESPONSE_TIMEOUT_MS,
    })


func _flush_pending_reset_waiters() -> void:
    var generation := _active_reset_generation
    if generation <= 0:
        return
    if not _reset_status_handler.is_valid():
        return
    # Completion wins the race with a caller deadline: once runtime has
    # committed, reset publication and its matching success responses are the
    # only valid outcome, even if this poll happens after the deadline.
    var status = _reset_status_handler.call(generation)
    if typeof(status) != TYPE_DICTIONARY:
        _complete_reset_waiters(generation, false, "reset status handler returned an invalid result")
        return
    var state := String(status.get("state", "pending"))
    if state == "committed":
        _publish_reset_commit()
        _complete_reset_waiters(generation, true)
        return
    if state != "pending":
        _complete_reset_waiters(generation, false, String(status.get("error", "reset failed")))
        return
    var now_ms := Time.get_ticks_msec()
    var timed_out := false
    for waiter in _pending_reset_waiters:
        if int(waiter["generation"]) == generation and now_ms >= int(waiter["deadline_ms"]):
            timed_out = true
            break
    if timed_out:
        if _reset_abort_handler.is_valid():
            _reset_abort_handler.call(generation, "RPC reset response timed out")
        _complete_reset_waiters(generation, false, "reset timeout")


func _publish_reset_commit() -> void:
    # This is the sole AirSim-facing reset publication for a deferred reset:
    # replay, session clock, and control latches change together immediately
    # before the corresponding transport replies are written.
    if _replay_simulation_handler.is_valid():
        _replay_simulation_handler.call(4, 0.0)
    session.reset()
    # Reset's native replay event must precede its baseline, while the public
    # session epoch must be zero before that baseline takes a timestamp.
    if _reset_environment_replay_handler.is_valid():
        _reset_environment_replay_handler.call()
    reset_vehicle_control_state()


func _complete_reset_waiters(generation: int, ok: bool, error: String = "") -> void:
    for waiter in _pending_reset_waiters.duplicate():
        if int(waiter["generation"]) != generation:
            continue
        _pending_reset_waiters.erase(waiter)
        var client: StreamPeerTCP = waiter["client"]
        if not _client_is_current(client, int(waiter["client_epoch"])):
            continue
        var response := _success_response(waiter["message_id"], null) if ok else _error_response(waiter["message_id"], error)
        _send_or_remove(client, response)
    if _active_reset_generation == generation:
        _active_reset_generation = 0


func _client_is_current(client: StreamPeerTCP, epoch: int) -> bool:
    return _clients.has(client) and int(_client_epochs.get(client.get_instance_id(), -1)) == epoch


func _send_or_remove(client: StreamPeerTCP, response: Array) -> void:
    if not _send_response(client, response):
        _remove_client(client)


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
            if _replay_async_handler.is_valid():
                _replay_async_handler.call(session.simulation_time_seconds, String(pending["vehicle_name"]),
                    "%s" % pending.get("command_id", pending["message_id"]), String(pending.get("method", "")), 4)
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
        if _replay_async_handler.is_valid():
            _replay_async_handler.call(session.simulation_time_seconds, String(pending["vehicle_name"]),
                "%s" % pending.get("command_id", pending["message_id"]), String(pending.get("method", "")), 2)
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
    var validation := _validate_request(request)
    if not bool(validation["ok"]):
        return _error_response(validation["message_id"], String(validation["error"]))
    var message_id = request[1]
    var method: String = request[2]
    var params: Array = request[3]
    if _is_mutating_method(method):
        var publication_error := _publication_error()
        if not publication_error.is_empty():
            return _error_response(message_id, publication_error)

    match method:
        "ping":
            return _success_response(message_id, true)
        "simPause":
            if params.size() != 1 or typeof(params[0]) != TYPE_BOOL:
                return _error_response(message_id, "simPause expects one boolean parameter")
            session.set_paused(params[0])
            if _replay_simulation_handler.is_valid():
                _replay_simulation_handler.call(0 if params[0] else 1, 0.0)
            return _success_response(message_id, null)
        "simIsPaused":
            if not params.is_empty():
                return _error_response(message_id, "simIsPaused expects no parameters")
            return _success_response(message_id, session.is_paused())
        "simContinueForFrames":
            if params.size() != 1 or typeof(params[0]) != TYPE_INT:
                return _error_response(message_id, "simContinueForFrames expects one integer parameter")
            var frame_result := session.continue_for_frames(params[0])
            if bool(frame_result.get("ok", false)) and _replay_simulation_handler.is_valid():
                _replay_simulation_handler.call(2, float(params[0]))
            return _session_response(message_id, frame_result)
        "simContinueForTime":
            if params.size() != 1 or (typeof(params[0]) != TYPE_FLOAT and typeof(params[0]) != TYPE_INT):
                return _error_response(message_id, "simContinueForTime expects one numeric parameter")
            var time_result := session.continue_for_time(float(params[0]))
            if bool(time_result.get("ok", false)) and _replay_simulation_handler.is_valid():
                _replay_simulation_handler.call(3, float(params[0]))
            return _session_response(message_id, time_result)
        "reset":
            if not params.is_empty():
                return _error_response(message_id, "reset expects no parameters")
            if reset_handler.is_valid():
                var reset_result = reset_handler.call()
                if typeof(reset_result) == TYPE_DICTIONARY and not bool(reset_result.get("ok", false)):
                    return _error_response(message_id, String(reset_result.get("error", "reset rejected")))
            _publish_reset_commit()
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
        "simListSceneObjects", "simSpawnObject", "simGetObjectPose", "simSetObjectPose", "simDestroyObject", "simGetSegmentationObjectID", "simSetSegmentationObjectID":
            return _dispatch_scene_object(message_id, method, params)
        "simEnableWeather", "simSetWeatherParameter", "simSetTimeOfDay", "simSetEnvironment", "simGetEnvironment":
            return _dispatch_environment(message_id, method, params)
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


func _validate_request(request: Array) -> Dictionary:
    if request.size() != 4:
        return {"ok": false, "message_id": null, "error": "RPC request must contain four fields"}
    if request[0] != 0:
        return {"ok": false, "message_id": request[1], "error": "unsupported RPC request type"}
    if typeof(request[2]) != TYPE_STRING or typeof(request[3]) != TYPE_ARRAY:
        return {"ok": false, "message_id": request[1], "error": "RPC method and params have invalid types"}
    return {"ok": true, "message_id": request[1], "error": ""}


func _dispatch_scene_object(message_id, method: String, params: Array) -> Array:
    if not _scene_object_handler.is_valid():
        return _error_response(message_id, "scene object catalog backend is unavailable")
    if method == "simListSceneObjects":
        if params.size() != 1 and not params.is_empty():
            return _error_response(message_id, "simListSceneObjects expects an optional name regex")
        if params.size() == 1 and typeof(params[0]) != TYPE_STRING:
            return _error_response(message_id, "simListSceneObjects name regex must be a string")
    elif method == "simSpawnObject":
        if params.size() != 5 and params.size() != 6:
            return _error_response(message_id, "simSpawnObject expects object name, catalog asset, pose, scale, and physics flag")
        if typeof(params[0]) != TYPE_STRING or typeof(params[1]) != TYPE_STRING or typeof(params[2]) != TYPE_DICTIONARY or typeof(params[3]) != TYPE_DICTIONARY or typeof(params[4]) != TYPE_BOOL:
            return _error_response(message_id, "simSpawnObject has invalid parameter types")
        if params.size() == 6 and typeof(params[5]) != TYPE_BOOL:
            return _error_response(message_id, "simSpawnObject blueprint flag must be boolean")
    elif method == "simGetObjectPose" or method == "simDestroyObject":
        if params.size() != 1 or typeof(params[0]) != TYPE_STRING:
            return _error_response(message_id, "%s expects one object name" % method)
    elif method == "simSetObjectPose":
        if params.size() != 3 or typeof(params[0]) != TYPE_STRING or typeof(params[1]) != TYPE_DICTIONARY or typeof(params[2]) != TYPE_BOOL:
            return _error_response(message_id, "simSetObjectPose expects object name, pose, and teleport flag")
    elif method == "simGetSegmentationObjectID":
        if params.size() != 1 or typeof(params[0]) != TYPE_STRING:
            return _error_response(message_id, "simGetSegmentationObjectID expects one object name")
    elif method == "simSetSegmentationObjectID":
        if params.size() != 3 or typeof(params[0]) != TYPE_STRING or typeof(params[1]) != TYPE_INT or typeof(params[2]) != TYPE_BOOL:
            return _error_response(message_id, "simSetSegmentationObjectID expects object name, integer ID, and regex flag")
    var backend_params: Array = params.duplicate()
    if method == "simListSceneObjects" and backend_params.is_empty():
        backend_params.append(".*")
    var result: Dictionary = _scene_object_handler.call(method, backend_params)
    return _backend_response(message_id, result)


func _dispatch_environment(message_id: int, method: String, params: Array) -> Array:
    if not _environment_handler.is_valid():
        return _error_response(message_id, "environment backend is unavailable")
    match method:
        "simEnableWeather":
            if params.size() != 1 or typeof(params[0]) != TYPE_BOOL:
                return _error_response(message_id, "simEnableWeather expects one boolean parameter")
        "simSetWeatherParameter":
            if params.size() != 2 or typeof(params[0]) != TYPE_INT or typeof(params[1]) != TYPE_FLOAT and typeof(params[1]) != TYPE_INT:
                return _error_response(message_id, "simSetWeatherParameter expects an integer parameter and numeric value")
            if int(params[0]) not in [0, 7]:
                return _error_response(message_id, "only AirSim Rain (0) and Fog (7) are supported")
            if float(params[1]) < 0.0 or float(params[1]) > 1.0:
                return _error_response(message_id, "weather value must be in the range 0..1")
        "simSetTimeOfDay":
            if params.size() != 6 or typeof(params[0]) != TYPE_BOOL or typeof(params[1]) != TYPE_STRING or typeof(params[2]) != TYPE_BOOL or (typeof(params[3]) != TYPE_FLOAT and typeof(params[3]) != TYPE_INT) or (typeof(params[4]) != TYPE_FLOAT and typeof(params[4]) != TYPE_INT) or typeof(params[5]) != TYPE_BOOL:
                return _error_response(message_id, "simSetTimeOfDay has invalid parameters")
            if float(params[3]) <= 0.0 or float(params[4]) <= 0.0:
                return _error_response(message_id, "time-of-day clock speed and update interval must be positive")
        "simSetEnvironment":
            if params.size() != 1 or typeof(params[0]) != TYPE_DICTIONARY:
                return _error_response(message_id, "simSetEnvironment expects one state object")
        "simGetEnvironment":
            if not params.is_empty():
                return _error_response(message_id, "simGetEnvironment expects no parameters")
    var result: Dictionary = _environment_handler.call(method, params)
    return _backend_response(message_id, result)


func _backend_response(message_id: int, result: Dictionary) -> Array:
    if not result.get("ok", false):
        return _error_response(message_id, String(result.get("error", "backend rejected request")))
    return _success_response(message_id, result.get("value"))


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
    var publication_error := _publication_error()
    if not publication_error.is_empty():
        return _error_response(message_id, publication_error)
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
    state.erase("aerosim_identity")
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
    var publication_error := _publication_error()
    if not publication_error.is_empty():
        return _error_response(message_id, publication_error)
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


func _publication_error() -> String:
    if not _publication_error_handler.is_valid():
        return ""
    return String(_publication_error_handler.call())


func _is_mutating_method(method: String) -> bool:
    return method in [
        "simPause", "simContinueForFrames", "simContinueForTime",
        "enableApiControl", "armDisarm", "cancelLastTask",
        "simSpawnObject", "simSetObjectPose", "simDestroyObject", "simSetSegmentationObjectID",
        "simEnableWeather", "simSetWeatherParameter", "simSetTimeOfDay", "simSetEnvironment",
    ] or _is_async_vehicle_method(method)


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
