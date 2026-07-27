extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

class SuppressedGspServer extends GspServer:
	var suppress_send := false

	func _flush_telemetry(record: Dictionary) -> void:
		if suppress_send:
			return
		super._flush_telemetry(record)


var _server: SuppressedGspServer
var _client := WebSocketPeer.new()
var _second_client := WebSocketPeer.new()
var _source_count := 0
var _freeze_source := false
var _telemetry_ticks: Array[int] = []
var _second_telemetry_ticks: Array[int] = []
var _failures: Array[String] = []


func _init() -> void:
	_server = SuppressedGspServer.new()
	root.add_child(_server)
	_server.set_identity_provider(Callable(self, "_identity"))
	_server.set_telemetry_provider(Callable(self, "_telemetry"))
	var started := _server.start()
	_server.set_process(false)
	_expect(bool(started.get("ok", false)), "telemetry server starts")
	_expect(not _server.is_processing(), "manual integration disables automatic server processing")
	if not bool(started.get("ok", false)):
		_finish()
		return

	await _connect_client(_client, int(started.port))
	await _authenticate(_client, String(started.token))
	var first := await _next_telemetry(_client, _telemetry_ticks, 240)
	var first_data: Dictionary = first.get("d", {})
	_expect(_valid_telemetry_envelope(first), "telemetry uses the parent v2 envelope")
	_expect(int(first_data.get("sample_seq", 0)) > 0 and int(first.get("tick", -1)) > 0, "telemetry carries the current independent sample")
	_expect(first_data.get("world_frame", "") == "NED" and first_data.get("body_frame", "") == "FRD", "telemetry uses NED/FRD")
	_expect(first_data.get("units", "") == "SI", "telemetry uses SI units")
	_expect(first_data.has("pos_ned") and first_data.has("vel_ned") and first_data.has("att_euler_deg") and first_data.has("gyro_body"), "telemetry uses the approved public field names")
	_expect(first_data.get("att_euler_deg", []) is Array and first_data.get("att_euler_deg", []).size() == 3, "attitude uses [roll, pitch, yaw]")
	_expect(first_data.get("motor_order", []) == ["rear_right", "front_right", "rear_left", "front_left"], "telemetry uses Betaflight motor order")

	await _connect_client(_second_client, int(started.port))
	await _authenticate(_second_client, String(started.token))
	await _next_telemetry(_second_client, _second_telemetry_ticks, 240)
	_drain_client(_client, _telemetry_ticks)
	_drain_client(_second_client, _second_telemetry_ticks)

	var paused_base := await _next_telemetry(_client, _telemetry_ticks, 240)
	_freeze_source = true
	var paused_sample_seq := int(paused_base.get("d", {}).get("sample_seq", 0))
	_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 1, "d": {"hz": 0, "extra": []}}))
	await _poll_all_for_msec(120)
	var hidden_count := _telemetry_ticks.size()
	await _poll_all_for_msec(120)
	_expect(_telemetry_ticks.size() == hidden_count, "rate zero stops telemetry after polling both endpoints")

	_client.send_text(JSON.stringify({"v": 2, "t": "request_snapshot", "seq": 2, "d": {}}))
	await _poll_all_for_msec(120)
	_expect(_telemetry_ticks.size() == hidden_count, "paused snapshot request does not send while rate is zero")
	_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 3, "d": {"hz": 30, "extra": []}}))
	var paused_restore := await _next_telemetry(_client, _telemetry_ticks, 240)
	var paused_restore_data: Dictionary = paused_restore.get("d", {})
	_expect(int(paused_restore_data.get("request_seq", -1)) == 2, "paused restore correlates the requesting client sequence")
	_expect(int(paused_restore_data.get("sample_seq", -1)) == paused_sample_seq, "paused restore succeeds without a new source sample")

	_freeze_source = false
	_drain_client(_client, _telemetry_ticks)
	_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 4, "d": {"hz": 5, "extra": []}}))
	var positive_rate_sample := await _next_telemetry(_client, _telemetry_ticks, 240)
	_expect(not bool(positive_rate_sample.get("d", {}).get("fresh", false)), "positive rate does not imply freshness")

	_second_client.send_text(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 1, "d": {"hz": 10, "extra": []}}))
	var first_cadence_start := _telemetry_ticks.size()
	var second_cadence_start := _second_telemetry_ticks.size()
	await _poll_all_for_msec(650)
	var first_cadence_samples := _telemetry_ticks.size() - first_cadence_start
	var second_cadence_samples := _second_telemetry_ticks.size() - second_cadence_start
	_expect(first_cadence_samples >= 2 and first_cadence_samples <= 6, "first peer keeps its 5 Hz cadence")
	_expect(second_cadence_samples >= 5 and second_cadence_samples <= 10, "second peer independently keeps its 10 Hz cadence")

	_second_client.close()
	await _poll_server_only_for_msec(120)
	_expect(_server.get_authenticated_peer_count() == 1, "stall test uses one authenticated peer")
	_client.send_text(JSON.stringify({"v": 2, "t": "request_snapshot", "seq": 5, "d": {}}))
	_server.suppress_send = true
	await _poll_server_only_for_msec(3000)
	var stall_end_tick := _source_count
	var stalled_record: Dictionary = {}
	for record in _server._authenticated_peers:
		if int(record.get("telemetry_rate_hz", 0)) == 5:
			stalled_record = record
	var stalled_diagnostics := _server.get_peer_transport_diagnostics()
	var stalled_peer_diagnostics: Dictionary = {}
	for diagnostic in stalled_diagnostics:
		if int(diagnostic.get("telemetry_rate_hz", 0)) == 5:
			stalled_peer_diagnostics = diagnostic
	_expect(int(stalled_peer_diagnostics.get("telemetry_slot_sample_seq", 0)) > 0, "diagnostics expose the nested occupied telemetry sample")
	_expect(int(stalled_peer_diagnostics.get("telemetry_slot_tick", 0)) >= stall_end_tick - 2 and int(stalled_peer_diagnostics.get("telemetry_slot_tick", 0)) <= stall_end_tick + 2, "unsent depth-one slot advances near the stall end")
	_expect(bool(stalled_record.get("telemetry_force_snapshot", false)) and int(stalled_record.get("telemetry_slot", {}).get("d", {}).get("request_seq", -1)) == 5, "suppression retains freshness and request correlation")

	_server.suppress_send = false
	var recovered := await _next_telemetry(_client, _telemetry_ticks, 240)
	_expect(_valid_telemetry_envelope(recovered), "released client receives an enveloped telemetry sample")
	_expect(int(recovered.get("tick", 0)) >= stall_end_tick - 2 and int(recovered.get("tick", 0)) <= stall_end_tick + 2, "released client receives the current slot")
	_expect(int(recovered.get("d", {}).get("request_seq", -1)) == 5, "released frame preserves the paused request correlation")

	_client.send_text(JSON.stringify({"v": 2, "t": "ping", "seq": 6, "d": {"sent_at_perf_ms": 1.0}}))
	var pong := await _next_message_type(_client, "pong", 240)
	_expect(String(pong.get("t", "")) == "pong" and pong.get("d", {}).has("echo"), "reliable ping/pong remains available")

	var processing := _server.get_telemetry_processing_diagnostics()
	_expect(String(processing.get("path", "")) == "always_process", "telemetry processing is attributed outside physics")
	_expect(int(processing.get("snapshot_serialization_count", 0)) > 0 and int(processing.get("send_count", 0)) > 0, "telemetry serialization and sending are measured")
	var serialization_samples: Array = processing.get("serialization_samples_usec", [])
	_expect(not serialization_samples.is_empty(), "telemetry serialization exposes a bounded distribution")
	_expect(float(processing.get("serialization_p99_usec", 501.0)) < 500.0, "telemetry serialization p99 remains below 0.5 ms")

	_client.close()
	_second_client.close()
	_server.stop()
	_finish()


func _connect_client(client: WebSocketPeer, port: int) -> void:
	client.handshake_headers = PackedStringArray(["Origin: null"])
	client.connect_to_url("ws://127.0.0.1:%d" % port)
	for _attempt in 240:
		_server.poll()
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return
		await process_frame


func _authenticate(client: WebSocketPeer, token: String) -> void:
	client.send_text(JSON.stringify({"v": 2, "t": "auth", "seq": 0, "d": {"token": token}}))
	var hello := await _next_message(client, 240)
	_expect(String(hello.get("t", "")) == "hello", "telemetry client authenticates")


func _next_message(client: WebSocketPeer, attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		client.poll()
		while client.get_available_packet_count() > 0:
			var packet := client.get_packet()
			if client.was_string_packet():
				var parsed = JSON.parse_string(packet.get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					return parsed
		await process_frame
	return {}


func _next_telemetry(client: WebSocketPeer, tick_log: Array[int], attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		client.poll()
		var packet := _read_packets(client, tick_log)
		if not packet.is_empty():
			return packet
		await process_frame
	return {}


func _next_message_type(client: WebSocketPeer, message_type: String, attempts: int) -> Dictionary:
	for _attempt in attempts:
		_server.poll()
		client.poll()
		while client.get_available_packet_count() > 0:
			var packet := client.get_packet()
			if not client.was_string_packet():
				continue
			var parsed = JSON.parse_string(packet.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY and String(parsed.get("t", "")) == message_type:
				return parsed
		await process_frame
	return {}


func _poll_all_for_msec(duration_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_msec
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		_client.poll()
		_second_client.poll()
		_read_packets(_client, _telemetry_ticks)
		_read_packets(_second_client, _second_telemetry_ticks)
		await process_frame


func _poll_server_only_for_msec(duration_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_msec
	while Time.get_ticks_msec() < deadline:
		_server.poll()
		await process_frame


func _read_packets(client: WebSocketPeer, tick_log: Array[int]) -> Dictionary:
	var first_telemetry: Dictionary = {}
	while client.get_available_packet_count() > 0:
		var packet := client.get_packet()
		if not client.was_string_packet():
			continue
		var parsed = JSON.parse_string(packet.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY or String(parsed.get("t", "")) != "telemetry":
			continue
		var data: Dictionary = parsed.get("d", {})
		tick_log.append(int(parsed.get("tick", 0)))
		if first_telemetry.is_empty():
			first_telemetry = parsed
	return first_telemetry


func _drain_client(client: WebSocketPeer, tick_log: Array[int]) -> void:
	client.poll()
	_read_packets(client, tick_log)


func _valid_telemetry_envelope(message: Dictionary) -> bool:
	return message.get("v", -1) == 2 and message.get("t", "") == "telemetry" and message.has("seq") and message.has("tick") and typeof(message.get("d")) == TYPE_DICTIONARY and message.get("d", {}).has("sample_seq")


func _identity() -> Dictionary:
	return {"vehicle_instance": "Drone1", "authority": "flight_controller", "registry_hash": "fixture", "tick": _source_count}


func _telemetry() -> Dictionary:
	if not _freeze_source:
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
		"att_euler_deg": [0.0, 0.0, 0.0],
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
