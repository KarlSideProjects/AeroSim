extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _failures: Array[String] = []


func _init() -> void:
	await _run()
	if _failures.is_empty():
		print("GSP transport boundary: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("GSP transport boundary: FAIL")
		quit(1)


func _run() -> void:
	await _test_port_fallback_and_exhaustion()
	if not await _start_server():
		return
	await _test_auth_boundary_table()
	await _test_fractional_tick()
	await _test_late_authentication()
	await _test_nested_string_bound()
	await _test_sequence_gap()
	await _test_two_authenticated_peers_and_destination_bound()
	await _test_excess_handshakes_and_total_bound()
	_server.stop()
	await _wait_for_live_peers(0, 1000)


func _start_server() -> bool:
	_server = GspServer.new()
	get_root().add_child(_server)
	_server.set_identity_provider(Callable(self, "_identity"))
	var result := _server.start()
	_expect(bool(result.get("ok", false)), "server starts for transport boundary tests")
	return bool(result.get("ok", false))


func _test_port_fallback_and_exhaustion() -> void:
	var occupied := TCPServer.new()
	_expect(occupied.listen(8765, "127.0.0.1") == OK, "port fallback fixture occupies the first port")
	var fallback_server := GspServer.new()
	get_root().add_child(fallback_server)
	var fallback := fallback_server.start()
	_expect(bool(fallback.get("ok", false)) and int(fallback.get("port", 0)) != 8765, "server falls back from an occupied port")
	fallback_server.stop()
	var all_occupied: Array[TCPServer] = [occupied]
	for port in [8766, 8767, 8768, 8769]:
		var listener := TCPServer.new()
		_expect(listener.listen(port, "127.0.0.1") == OK, "port exhaustion fixture occupies port %d" % port)
		all_occupied.append(listener)
	var exhausted := fallback_server.start()
	_expect(not bool(exhausted.get("ok", true)) and not fallback_server.is_listening(), "all-port failure is nonfatal and leaves no listener")
	for listener in all_occupied:
		listener.stop()
	var recovered := fallback_server.start()
	_expect(bool(recovered.get("ok", false)) and fallback_server.is_listening(), "listener recovers after all ports are released")
	fallback_server.stop()
	fallback_server.queue_free()
	await process_frame


func _test_auth_boundary_table() -> void:
	var token := _server.get_token()
	var cases := [
		{"name": "wrong token", "message": _auth_message(token.reverse()), "accepted": false},
		{"name": "malformed json", "message": "{not-json", "accepted": false},
		{"name": "non-finite version", "message": "{\"v\":NaN,\"t\":\"auth\",\"seq\":0,\"d\":{\"token\":\"%s\"}}" % token, "accepted": false},
		{"name": "non-finite sequence", "message": "{\"v\":2,\"t\":\"auth\",\"seq\":Infinity,\"d\":{\"token\":\"%s\"}}" % token, "accepted": false},
		{"name": "non-auth first envelope", "message": JSON.stringify({"v": 2, "t": "ping", "seq": 0, "d": {}}), "accepted": false},
		{"name": "wrong version", "message": JSON.stringify({"v": 1, "t": "auth", "seq": 0, "d": {"token": token}}), "accepted": false},
		{"name": "fractional version", "message": JSON.stringify({"v": 2.5, "t": "auth", "seq": 0, "d": {"token": token}}), "accepted": false},
		{"name": "fractional auth sequence", "message": JSON.stringify({"v": 2, "t": "auth", "seq": 0.5, "d": {"token": token}}), "accepted": false},
		{"name": "near integer auth sequence", "message": JSON.stringify({"v": 2, "t": "auth", "seq": 1.0000000000000002, "d": {"token": token}}), "accepted": false},
		{"name": "negative auth sequence", "message": JSON.stringify({"v": 2, "t": "auth", "seq": -1, "d": {"token": token}}), "accepted": false},
		{"name": "unsafe auth sequence", "message": JSON.stringify({"v": 2, "t": "auth", "seq": 9007199254740992, "d": {"token": token}}), "accepted": false},
		{"name": "auth sequence one", "message": JSON.stringify({"v": 2, "t": "auth", "seq": 1, "d": {"token": token}}), "accepted": false},
		{"name": "integral spellings", "message": "{\"v\":2e0,\"t\":\"auth\",\"seq\":0.0,\"tick\":0e0,\"d\":{\"token\":\"%s\"}}" % token, "accepted": true},
	]
	for test_case in cases:
		var client := await _open_client()
		if client == null:
			continue
		var sent := client.send_text(String(test_case.message))
		_expect(sent == OK, "%s test message sends" % test_case.name)
		var hello := await _next_message(client, 1000)
		var accepted := bool(test_case.get("accepted", false))
		if accepted:
			_expect(String(hello.get("t", "")) == "hello", "%s accepts integral JSON spellings" % test_case.name)
			await _close_client(client)
		else:
			_expect(await _wait_closed(client, 2500), "%s is closed" % test_case.name)
		await _wait_for_live_peers(0, 1000)

	var binary_client := await _open_client()
	if binary_client != null:
		_expect(binary_client.send(PackedByteArray([123, 125])) == OK, "non-string packet sends")
		_expect(await _wait_closed(binary_client, 1000), "non-string packet is closed")
		await _wait_for_live_peers(0, 1000)

	var oversized_client := await _open_client()
	if oversized_client != null:
		_expect(oversized_client.send_text("x".repeat(GspServer.MAX_MESSAGE_BYTES + 1)) == OK, "oversized packet sends")
		_expect(await _wait_closed(oversized_client, 1000), "oversized packet is closed")
		await _wait_for_live_peers(0, 1000)


func _test_late_authentication() -> void:
	var client := await _open_client()
	if client == null:
		return
	_expect(await _wait_closed(client, GspServer.OPEN_UNAUTHENTICATED_TIMEOUT_MS + 1000), "late authentication is closed")
	await _wait_for_live_peers(0, 1000)


func _test_fractional_tick() -> void:
	var client := await _authenticated_client()
	if client == null:
		return
	_expect(client.send_text("{\"v\":2,\"t\":\"ping\",\"seq\":1,\"tick\":1.5,\"d\":{}}") == OK, "fractional tick sends")
	_expect(await _wait_closed(client, 1000), "fractional tick is closed")
	await _wait_for_live_peers(0, 1000)


func _test_nested_string_bound() -> void:
	var client := await _authenticated_client()
	if client == null:
		return
	var oversized_string := {"v": 2, "t": "ping", "seq": 1, "d": {"text": "x".repeat(GspServer.MAX_STRING_BYTES + 1)}}
	_expect(client.send_text(JSON.stringify(oversized_string)) == OK, "oversized nested string sends")
	_expect(await _wait_closed(client, 1000), "oversized nested string is closed")
	await _wait_for_live_peers(0, 1000)


func _test_sequence_gap() -> void:
	var client := await _authenticated_client()
	if client == null:
		return
	_expect(client.send_text(JSON.stringify({"v": 2, "t": "ping", "seq": 1, "d": {"request": "first"}})) == OK, "first sequential ping sends")
	var pong := await _next_message(client, 1000)
	_expect(String(pong.get("t", "")) == "pong", "first sequential ping receives pong")
	_expect(client.send_text(JSON.stringify({"v": 2, "t": "ping", "seq": 3, "d": {"request": "gap"}})) == OK, "sequence gap sends")
	_expect(await _wait_closed(client, 1000), "sequence gap is closed")
	await _wait_for_live_peers(0, 1000)


func _test_two_authenticated_peers_and_destination_bound() -> void:
	var first := await _authenticated_client()
	var unauthenticated := await _open_client()
	var second := await _authenticated_client()
	if first == null or unauthenticated == null or second == null:
		return
	_expect(_server.get_authenticated_peer_count() == 2, "two authenticated peers are supported")
	_expect(_server.get_unauthenticated_peer_count() == 1, "open unauthenticated destination remains observable")
	var token := _server.get_token()
	_expect(unauthenticated.send_text(_auth_message(token)) == OK, "third auth attempt sends")
	_expect(await _wait_closed(unauthenticated, 1000), "authentication destination bound closes excess peer")
	await _close_client(first)
	await _close_client(second)
	await _wait_for_live_peers(0, 1000)

	var auth_a := await _authenticated_client()
	var auth_b := await _authenticated_client()
	var excess := await _open_client()
	if auth_a != null and auth_b != null and excess != null:
		_expect(await _wait_closed(excess, 1000), "excess authenticated peer is closed")
		await _close_client(auth_a)
		await _close_client(auth_b)
	await _wait_for_live_peers(0, 1000)


func _test_excess_handshakes_and_total_bound() -> void:
	var clients: Array[WebSocketPeer] = []
	for _index in GspServer.MAX_UNAUTHENTICATED_PEERS:
		var client := await _open_client()
		if client != null:
			clients.append(client)
	_expect(_server.get_live_peer_count() <= GspServer.MAX_LIVE_PEERS, "live peer bound holds across handshake transitions")
	_expect(_server.get_unauthenticated_peer_count() <= GspServer.MAX_UNAUTHENTICATED_PEERS, "unauthenticated peer bound holds after transition")
	var excess := await _open_client()
	if excess != null:
		_expect(await _wait_closed(excess, 1000), "excess handshake peer is rejected")
	for client in clients:
		await _close_client(client)
	await _wait_for_live_peers(0, 1000)


func _authenticated_client() -> WebSocketPeer:
	var client := await _open_client()
	if client == null:
		return null
	var token := _server.get_token()
	_expect(client.send_text(_auth_message(token)) == OK, "valid auth sends")
	var hello := await _next_message(client, 1000)
	_expect(String(hello.get("t", "")) == "hello", "valid auth receives hello")
	if String(hello.get("t", "")) != "hello":
		await _close_client(client)
		return null
	var identity: Dictionary = hello.get("d", {})
	for key in ["sim_version", "proto_v", "physics_hz", "pid", "instance_name", "registry", "registry_hash", "peer", "process", "vehicle_instance", "authority", "sequence"]:
		_expect(identity.has(key), "hello identity includes %s" % key)
	_expect(int(hello.get("v", -1)) == 2 and int(hello.get("seq", 0)) == 1, "hello uses v2 and server sequence one")
	return client


func _open_client() -> WebSocketPeer:
	var client := WebSocketPeer.new()
	client.handshake_headers = PackedStringArray(["Origin: null"])
	var error := client.connect_to_url("ws://127.0.0.1:%d" % _server.get_port())
	_expect(error == OK, "WebSocket client starts connecting")
	if error != OK:
		return null
	for _attempt in 240:
		_server.poll()
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return client
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return client
		await process_frame
	_expect(false, "WebSocket client reaches a terminal handshake state")
	return client


func _next_message(client: WebSocketPeer, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		client.poll()
		if client.get_available_packet_count() > 0:
			var packet := client.get_packet()
			if not client.was_string_packet():
				return {}
			var parsed = JSON.parse_string(packet.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				return parsed
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return {}
		await process_frame
	return {}


func _wait_closed(client: WebSocketPeer, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return true
		await process_frame
	return client.get_ready_state() == WebSocketPeer.STATE_CLOSED


func _close_client(client: WebSocketPeer) -> void:
	if client == null:
		return
	client.close()
	await _wait_closed(client, 1000)


func _wait_for_live_peers(expected: int, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		if _server.get_live_peer_count() == expected:
			return true
		await process_frame
	_expect(_server.get_live_peer_count() == expected, "server reclaims peers to count %d" % expected)
	return _server.get_live_peer_count() == expected


func _auth_message(token: String) -> String:
	return JSON.stringify({"v": 2, "t": "auth", "seq": 0, "d": {"token": token}})


func _identity() -> Dictionary:
	return {
		"sim_version": "fixture-1",
		"proto_v": 2,
		"physics_hz": 240,
		"pid": 4242,
		"instance_name": "Drone1",
		"vehicle_instance": "Drone1",
		"authority": "flight",
		"registry": {"vehicle_instances": ["Drone1", "Drone2"]},
		"registry_hash": "unavailable",
		"tick": 7,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
