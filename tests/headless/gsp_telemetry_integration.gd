extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _client := WebSocketPeer.new()
var _source_count := 0
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
	var first := await _next_message(240)
	_expect(String(first.get("t", "")) == "telemetry", "authenticated client receives telemetry outside reliable messages")
	var first_sample := int(first.get("sample_seq", 0))
	_expect(first_sample > 0 and int(first.get("tick", -1)) > 0, "telemetry carries the current independent sample")
	_expect(first.get("world_frame", "") == "NED" and first.get("body_frame", "") == "FRD", "telemetry uses NED/FRD")
	_expect(first.get("units", "") == "SI", "telemetry uses SI units")

	_drain_client()
	_client.send_text(JSON.stringify({"v": 2, "t": "telemetry_rate", "seq": 1, "d": {"rate_hz": 0}}))
	await _poll_for_msec(120)
	_expect(_client.get_available_packet_count() == 0, "hidden telemetry rate stops new samples")

	_client.send_text(JSON.stringify({"v": 2, "t": "telemetry_request", "seq": 2, "d": {"fresh": true}}))
	_client.send_text(JSON.stringify({"v": 2, "t": "telemetry_rate", "seq": 3, "d": {"rate_hz": 30}}))
	var fresh := await _next_message(240)
	_expect(String(fresh.get("t", "")) == "telemetry", "return requests a fresh telemetry sample")
	_expect(int(fresh.get("sample_seq", 0)) > first_sample, "fresh sample advances independent sample sequence")

	await _poll_for_msec(3000)
	_drain_client()
	_client.poll()
	_client.send_text(JSON.stringify({"v": 2, "t": "telemetry_request", "seq": 4, "d": {"fresh": true}}))
	_client.send_text(JSON.stringify({"v": 2, "t": "telemetry_rate", "seq": 5, "d": {"rate_hz": 30}}))
	var current := await _next_fresh_message(240)
	_expect(String(current.get("t", "")) == "telemetry", "stalled client receives telemetry after recovery")
	_expect(int(current.get("tick", 0)) >= _source_count - 30, "stalled client receives current telemetry, not queued history")
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
		if _client.get_available_packet_count() > 0:
			var packet := _client.get_packet()
			if _client.was_string_packet():
				var parsed = JSON.parse_string(packet.get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					return parsed
		await process_frame
	return {}


func _poll_for_msec(duration_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_msec
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		await process_frame


func _drain_client() -> void:
	_client.poll()
	while _client.get_available_packet_count() > 0:
		_client.get_packet()


func _next_fresh_message(attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		_client.poll()
		while _client.get_available_packet_count() > 0:
			var packet := _client.get_packet()
			if not _client.was_string_packet():
				continue
			var parsed = JSON.parse_string(packet.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY and bool(parsed.get("fresh", false)):
				return parsed
		await process_frame
	return {}


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
		"position_ned": {"x_val": float(_source_count), "y_val": 0.0, "z_val": 0.0},
		"velocity_ned_mps": {"x_val": 1.0, "y_val": 0.0, "z_val": 0.0},
		"attitude_ned": {"w_val": 1.0, "x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
		"rates_frd_rad_s": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
		"units": "SI",
		"world_frame": "NED",
		"body_frame": "FRD",
		"motor_order": ["rear_right", "front_right", "rear_left", "front_left"],
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
