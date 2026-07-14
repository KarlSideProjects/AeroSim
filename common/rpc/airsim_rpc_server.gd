class_name AirSimRpcServer
extends Node

const DEFAULT_BIND_ADDRESS := "127.0.0.1"
const DEFAULT_PORT: int = 41451
const MAX_CLIENTS: int = 16
const MAX_CLIENT_BUFFER_BYTES: int = 1_048_576

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


func set_session(owner_session: AirSimSession, owner_reset_handler: Callable = Callable()) -> void:
    if _running:
        stop()
    session = owner_session
    reset_handler = owner_reset_handler


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
    _running = false
    set_process(false)


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
        if is_explicit_step:
            _pending_step_responses.append({"client": client, "message_id": response[1]})
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
        _:
            return _error_response(message_id, "unsupported RPC method: %s" % method)


func _session_response(message_id, result: Dictionary) -> Array:
    if result.ok:
        return _success_response(message_id, null)
    return _error_response(message_id, result.error)


func _success_response(message_id, result) -> Array:
    return [1, message_id, null, result]


func _error_response(message_id, message: String) -> Array:
    return [1, message_id, message, null]
