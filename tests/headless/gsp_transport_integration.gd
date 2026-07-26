extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _client := WebSocketPeer.new()
var _failures: Array[String] = []


func _init() -> void:
	_run_integration()


func _run_integration() -> void:
	_server = GspServer.new()
	get_root().add_child(_server)
	_server.set_identity_provider(Callable(self, "_identity"))
	var started := _server.start()
	_expect(bool(started.get("ok", false)), "GSP server starts on a loopback fallback port")
	if not bool(started.get("ok", false)):
		_finish()
		return
	_server.set_process(false)
	_client.handshake_headers = PackedStringArray(["Origin: null"])
	_expect(_client.connect_to_url("ws://127.0.0.1:%d" % int(started.port)) == OK, "WebSocket client connects")
	if _client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_finish()
		return

	for _attempt in 240:
		_server.poll()
		_client.poll()
		if _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
			break
		await process_frame
	_expect(_client.get_ready_state() == WebSocketPeer.STATE_OPEN, "WebSocket handshake completes")
	if _client.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_finish()
		return

	var token := String(started.token)
	_expect(_client.send_text(JSON.stringify({"v": 2, "t": "auth", "seq": 1, "d": {"token": token}})) == OK, "client sends v2 auth")
	var hello := await _next_message(240)
	_expect(String(hello.get("t", "")) == "hello", "authenticated peer receives hello")
	_expect(int(hello.get("v", -1)) == 2, "hello uses v2 envelope")
	var hello_data: Dictionary = hello.get("d", {})
	for required_key in ["peer", "process", "vehicle_instance", "authority", "registry"]:
		_expect(hello_data.has(required_key), "hello carries %s identity" % required_key)

	var request_data := {"client_timestamp_ms": 12345, "request": "fixed-runner"}
	_expect(_client.send_text(JSON.stringify({"v": 2, "t": "ping", "seq": 2, "d": request_data})) == OK, "client sends v2 ping")
	var pong := await _next_message(240)
	_expect(String(pong.get("t", "")) == "pong", "authenticated peer receives pong")
	_expect(int(pong.get("v", -1)) == 2, "pong uses v2 envelope")
	var pong_data: Dictionary = pong.get("d", {})
	var echo: Dictionary = pong_data.get("echo", {})
	_expect(int(echo.get("client_timestamp_ms", -1)) == 12345 and String(echo.get("request", "")) == "fixed-runner", "pong echoes the client request data")
	_expect(pong_data.has("peer") and pong_data.has("registry"), "pong carries identity")

	_client.close()
	_server.stop()
	_finish()


func _next_message(attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		_client.poll()
		if _client.get_available_packet_count() > 0:
			var packet: PackedByteArray = _client.get_packet()
			if not _client.was_string_packet():
				return {}
			var parsed = JSON.parse_string(packet.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				return parsed
		await process_frame
	return {}


func _identity() -> Dictionary:
	return {
		"vehicle_instance": "Drone1",
		"authority": "flight",
		"registry": {"vehicle_instances": ["Drone1"], "config_hash": "fixture"},
		"tick": 7,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("GSP transport integration: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("GSP transport integration: FAIL")
		quit(1)
