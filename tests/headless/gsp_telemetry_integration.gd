extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _client := WebSocketPeer.new()
var _source_count := 0
var _telemetry_ticks: Array[int] = []
var _failures: Array[String] = []


func _init() -> void:
	_server = GspServer.new()
	root.add_child(_server)
	_server.set_identity_provider(Callable(self, "_identity"))
	_server.set_telemetry_provider(Callable(self, "_telemetry"))
	var started := _server.start()
	_expect(bool(started.get("ok", false)), "telemetry server starts")
	if not bool(started.get("ok", false)):
		_finish()
		return
	_client.handshake_headers = PackedStringArray(["Origin: null"])
	_client.connect_to_url("ws://127.0.0.1:%d" % int(started.port))
	await _wait_open()
	_expect(_client.get_ready_state() == WebSocketPeer.STATE_OPEN, "telemetry client connects")
	if _client.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_finish()
		return
	_client.send_text(JSON.stringify({"v": 2, "t": "auth", "seq": 0, "d": {"token": started.token}}))
	var hello := await _next_message(240)
	_expect(String(hello.get("t", "")) == "hello", "telemetry client authenticates")
	var first := await _next_telemetry(240)
	var first_data: Dictionary = first.get("d", {})
	_expect(_valid_telemetry_envelope(first), "telemetry uses the parent v2 envelope")
	_expect(int(first_data.get("sample_seq", 0)) > 0 and int(first.get("tick", -1)) > 0, "telemetry carries the current independent sample")
	_expect(first_data.get("world_frame", "") == "NED" and first_data.get("body_frame", "") == "FRD", "telemetry uses NED/FRD")
	_expect(first_data.get("units", "") == "SI", "telemetry uses SI units")
	_expect(first_data.has("pos_ned") and first_data.has("vel_ned") and first_data.has("att_euler_deg") and first_data.has("gyro_body"), "telemetry uses the approved public field names")
	_expect(first_data.get("motor_order", []) == ["rear_right", "front_right", "rear_left", "front_left"], "telemetry uses Betaflight motor order")

	_drain_client()
	_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 1, "d": {"hz": 0, "extra": false}}))
	await _poll_both_for_msec(120)
	var hidden_count := _telemetry_ticks.size()
	await _poll_both_for_msec(120)
	_expect(_telemetry_ticks.size() == hidden_count, "rate zero stops telemetry after polling both endpoints")

	_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 2, "d": {"hz": 5, "extra": false}}))
	var cadence_start := _telemetry_ticks.size()
	await _poll_both_for_msec(550)
	var cadence_samples := _telemetry_ticks.size() - cadence_start
	_expect(cadence_samples >= 2 and cadence_samples <= 4, "requested 5 Hz cadence is enforced")
	var diagnostics := _server.get_peer_transport_diagnostics()
	_expect(not diagnostics.is_empty() and int(diagnostics[0].get("telemetry_rate_hz", -1)) == 5, "peer stores requested telemetry cadence")

	_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 3, "d": {"hz": 30, "extra": false}}))
	await _poll_both_for_msec(120)
	var stall_start_tick := _source_count
	await _poll_server_only_for_msec(3000)
	var stall_end_tick := _source_count
	_drain_client()
	var first_after_stall := await _next_telemetry(240)
	var recovered_data: Dictionary = first_after_stall.get("d", {})
	_expect(_valid_telemetry_envelope(first_after_stall), "stalled client receives an enveloped telemetry sample")
	_expect(int(first_after_stall.get("tick", 0)) >= stall_start_tick and int(first_after_stall.get("tick", 0)) >= stall_end_tick - 2, "stale pre-recovery telemetry cannot satisfy recovery")
	_expect(int(recovered_data.get("sample_seq", 0)) > int(first_data.get("sample_seq", 0)), "recovery advances the independent sample sequence")

	_client.send_text(JSON.stringify({"v": 2, "t": "ping", "seq": 4, "d": {"sent_at_unix_ms": Time.get_unix_time_from_system() * 1000.0}}))
	var pong := await _next_message_type("pong", 240)
	_expect(String(pong.get("t", "")) == "pong" and pong.get("d", {}).has("echo"), "reliable ping/pong remains available")

	var processing := _server.get_telemetry_processing_diagnostics()
	_expect(String(processing.get("path", "")) == "always_process", "telemetry processing is attributed outside physics")
	_expect(int(processing.get("snapshot_serialization_count", 0)) > 0 and int(processing.get("send_count", 0)) > 0, "telemetry serialization and sending are measured")

	_server.stop()
	_finish()


func _wait_open() -> void:
	for _attempt in 240:
		_server.poll()
		_client.poll()
		if _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return
		await process_frame


func _next_message(attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		_client.poll()
		while _client.get_available_packet_count() > 0:
			var packet := _client.get_packet()
			if _client.was_string_packet():
				var parsed = JSON.parse_string(packet.get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					return parsed
		await process_frame
	return {}


func _next_telemetry(attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		_client.poll()
		var packet := _read_packets()
		if not packet.is_empty():
			return packet
		await process_frame
	return {}


func _next_message_type(message_type: String, attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		_client.poll()
		while _client.get_available_packet_count() > 0:
			var packet := _client.get_packet()
			if not _client.was_string_packet():
				continue
			var parsed = JSON.parse_string(packet.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY and String(parsed.get("t", "")) == message_type:
				return parsed
		await process_frame
	return {}


func _poll_both_for_msec(duration_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_msec
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		_client.poll()
		_read_packets()
		await process_frame


func _poll_server_only_for_msec(duration_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_msec
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		await process_frame


func _read_packets() -> Dictionary:
	var first_telemetry: Dictionary = {}
	while _client.get_available_packet_count() > 0:
		var packet := _client.get_packet()
		if not _client.was_string_packet():
			continue
		var parsed = JSON.parse_string(packet.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY or String(parsed.get("t", "")) != "telemetry":
			continue
		var data: Dictionary = parsed.get("d", {})
		_telemetry_ticks.append(int(parsed.get("tick", 0)))
		if first_telemetry.is_empty():
			first_telemetry = parsed
	return first_telemetry


func _drain_client() -> void:
	_client.poll()
	_read_packets()


func _valid_telemetry_envelope(message: Dictionary) -> bool:
	return message.get("v", -1) == 2 and message.get("t", "") == "telemetry" and message.has("seq") and message.has("tick") and typeof(message.get("d")) == TYPE_DICTIONARY and message.get("d", {}).has("sample_seq")


func _identity() -> Dictionary:
	return {"vehicle_instance": "Drone1", "authority": "flight_controller", "registry_hash": "fixture", "tick": _source_count}


func _telemetry() -> Dictionary:
	_source_count += 1
	return {
		"publish_count": _source_count,
		"timestamp_us": _source_count * 33333,
		"tick": _source_count,
		"snapshot_hz": 30.0,
		"vehicle_instance": "Drone1",
		"authority": "flight_controller",
		"registry_hash": "fixture",
		"pos_ned": {"x_val": float(_source_count), "y_val": 0.0, "z_val": 0.0},
		"vel_ned": {"x_val": 1.0, "y_val": 0.0, "z_val": 0.0},
		"att_euler_deg": {"roll": 0.0, "pitch": 0.0, "yaw": 0.0},
		"gyro_body": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
		"units": "SI",
		"world_frame": "NED",
		"body_frame": "FRD",
		"motor_order": ["rear_right", "front_right", "rear_left", "front_left"],
		"rpm": [1000.0, 1000.0, 1000.0, 1000.0],
		"motors": [],
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("GSP telemetry integration: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("GSP telemetry integration: FAIL")
		quit(1)
