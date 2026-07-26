extends Node
class_name GspServer

const BIND_ADDRESS := "127.0.0.1"
const PORT_RANGE: Array[int] = [8765, 8766, 8767, 8768, 8769]
const PROTOCOL_VERSION := 2
const TOKEN_BYTES := 16
const MAX_AUTHENTICATED_PEERS := 1
const MAX_PENDING_HANDSHAKES := 8
const MAX_UNAUTHENTICATED_PEERS := 8
const PENDING_HANDSHAKE_TIMEOUT_MS := 5_000
const OPEN_UNAUTHENTICATED_TIMEOUT_MS := 2_000
const MAX_MESSAGE_BYTES := 16_384
const MAX_RELIABLE_MESSAGES := 64
const MAX_RELIABLE_BYTES := 65_536

var reliable_overflow_count := 0
var reliable_send_failure_count := 0
var last_reliable_error := ""

var _tcp_server := TCPServer.new()
var _pending_handshakes: Array[Dictionary] = []
var _unauthenticated_peers: Array[Dictionary] = []
var _authenticated_peers: Array[Dictionary] = []
var _identity_provider: Callable
var _token := ""
var _port := 0
var _next_peer_id := 1
var _running := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(_running)


func _process(_delta: float) -> void:
	poll()


func start() -> Dictionary:
	stop()
	_token = generate_token()
	for candidate_port in PORT_RANGE:
		_tcp_server = TCPServer.new()
		var listen_error := _tcp_server.listen(candidate_port, BIND_ADDRESS)
		if listen_error == OK:
			_port = candidate_port
			_running = true
			set_process(true)
			return {"ok": true, "bind_address": BIND_ADDRESS, "port": _port, "token": _token}
		_tcp_server.stop()
	_running = false
	set_process(false)
	return {
		"ok": false,
		"bind_address": BIND_ADDRESS,
		"attempted_ports": PORT_RANGE.duplicate(),
		"error": "GSP could not bind 127.0.0.1 ports 8765 through 8769",
	}


func stop() -> void:
	if _tcp_server != null:
		_tcp_server.stop()
	for record in _pending_handshakes:
		_close_record(record, "server stopped")
	for record in _unauthenticated_peers:
		_close_record(record, "server stopped")
	for record in _authenticated_peers:
		_close_record(record, "server stopped")
	_pending_handshakes.clear()
	_unauthenticated_peers.clear()
	_authenticated_peers.clear()
	_running = false
	_port = 0
	set_process(false)


func is_running() -> bool:
	return _running


func is_listening() -> bool:
	return _tcp_server != null and _tcp_server.is_listening()


func get_port() -> int:
	return _port


func get_token() -> String:
	return _token


func set_identity_provider(provider: Callable) -> void:
	_identity_provider = provider


func poll() -> void:
	if not _running:
		return
	_accept_connections()
	_poll_pending_handshakes()
	_poll_unauthenticated_peers()
	_poll_authenticated_peers()


static func generate_token() -> String:
	return Crypto.new().generate_random_bytes(TOKEN_BYTES).hex_encode()


static func validate_bind_address(address: String) -> Dictionary:
	return {"ok": address == BIND_ADDRESS}


static func validate_auth_message(message: String, expected_token: String) -> Dictionary:
	var envelope_result := _parse_envelope(message, "auth")
	if not bool(envelope_result.get("ok", false)):
		return envelope_result
	var envelope: Dictionary = envelope_result.envelope
	var data: Dictionary = envelope.d
	if data.size() != 1 or typeof(data.get("token")) != TYPE_STRING:
		return {"ok": false, "error": "malformed auth data"}
	var received_token := String(data.token)
	var expected_token_bytes := expected_token.to_utf8_buffer()
	var received_token_bytes := received_token.to_utf8_buffer()
	if expected_token_bytes.size() != TOKEN_BYTES * 2 or received_token_bytes.size() != expected_token_bytes.size():
		return {"ok": false, "error": "wrong auth token"}
	var crypto := Crypto.new()
	if not crypto.constant_time_compare(expected_token_bytes, received_token_bytes):
		return {"ok": false, "error": "wrong auth token"}
	return {"ok": true, "seq": int(envelope.seq)}


static func validate_ping_message(message: String) -> Dictionary:
	var envelope_result := _parse_envelope(message, "ping")
	if not bool(envelope_result.get("ok", false)):
		return envelope_result
	var envelope: Dictionary = envelope_result.envelope
	return {"ok": true, "envelope": envelope}


static func _parse_envelope(message: String, expected_type: String) -> Dictionary:
	if message.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return {"ok": false, "error": "application message is oversized"}
	var parsed = JSON.parse_string(message)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "application message must be a Dictionary"}
	var envelope: Dictionary = parsed
	var allowed_keys := ["v", "t", "seq", "tick", "d"]
	for key in envelope.keys():
		if key not in allowed_keys:
			return {"ok": false, "error": "application envelope has an unknown field"}
	if envelope.size() < 4 or not envelope.has_all(["v", "t", "seq", "d"]):
		return {"ok": false, "error": "application envelope is incomplete"}
	if _integer_value(envelope.v) != PROTOCOL_VERSION:
		return {"ok": false, "error": "wrong GSP protocol version"}
	if typeof(envelope.t) != TYPE_STRING or String(envelope.t) != expected_type:
		return {"ok": false, "error": "unexpected GSP message type"}
	if _integer_value(envelope.seq) < 0:
		return {"ok": false, "error": "invalid GSP sequence"}
	if envelope.has("tick") and _integer_value(envelope.tick) < 0:
		return {"ok": false, "error": "invalid GSP tick"}
	if typeof(envelope.d) != TYPE_DICTIONARY:
		return {"ok": false, "error": "GSP data must be a Dictionary"}
	return {"ok": true, "envelope": envelope}


static func _integer_value(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and is_equal_approx(float(value), round(float(value))):
		return int(round(float(value)))
	return -1


func _accept_connections() -> void:
	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		if stream == null:
			break
		if _pending_handshakes.size() >= MAX_PENDING_HANDSHAKES or _unauthenticated_peers.size() >= MAX_UNAUTHENTICATED_PEERS:
			stream.disconnect_from_host()
			continue
		if _authenticated_peers.size() >= MAX_AUTHENTICATED_PEERS:
			stream.disconnect_from_host()
			continue
		var websocket := WebSocketPeer.new()
		websocket.inbound_buffer_size = MAX_MESSAGE_BYTES
		websocket.outbound_buffer_size = MAX_MESSAGE_BYTES
		websocket.max_queued_packets = MAX_RELIABLE_MESSAGES
		var accept_error := websocket.accept_stream(stream)
		if accept_error != OK:
			websocket.close()
			continue
		_pending_handshakes.append({
			"peer": websocket,
			"id": _next_peer_id,
			"deadline_ms": Time.get_ticks_msec() + PENDING_HANDSHAKE_TIMEOUT_MS,
		})
		_next_peer_id += 1


func _poll_pending_handshakes() -> void:
	for record in _pending_handshakes.duplicate():
		var peer: WebSocketPeer = record.peer
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_pending_handshakes.erase(record)
			continue
		if Time.get_ticks_msec() >= int(record.deadline_ms):
			_pending_handshakes.erase(record)
			_close_record(record, "handshake timeout")
			continue
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_pending_handshakes.erase(record)
			record["deadline_ms"] = Time.get_ticks_msec() + OPEN_UNAUTHENTICATED_TIMEOUT_MS
			_unauthenticated_peers.append(record)


func _poll_unauthenticated_peers() -> void:
	for record in _unauthenticated_peers.duplicate():
		var peer: WebSocketPeer = record.peer
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_unauthenticated_peers.erase(record)
			continue
		if Time.get_ticks_msec() >= int(record.deadline_ms):
			_unauthenticated_peers.erase(record)
			_close_record(record, "authentication timeout")
			continue
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN or peer.get_available_packet_count() == 0:
			continue
		var packet: PackedByteArray = peer.get_packet()
		if not peer.was_string_packet() or packet.size() > MAX_MESSAGE_BYTES:
			_unauthenticated_peers.erase(record)
			_close_record(record, "authentication required")
			continue
		var auth_result := validate_auth_message(packet.get_string_from_utf8(), _token)
		if not bool(auth_result.get("ok", false)):
			_unauthenticated_peers.erase(record)
			_close_record(record, "authentication rejected")
			continue
		_unauthenticated_peers.erase(record)
		record["state"] = "authenticated"
		record["reliable_queue"] = []
		record["reliable_bytes"] = 0
		record["sequence"] = 0
		record["client_sequence"] = int(auth_result.get("seq", -1))
		_authenticated_peers.append(record)
		if not _queue_identity_message(record, "hello", {}):
			_authenticated_peers.erase(record)
			_close_record(record, "reliable send failed")
		else:
			_flush_reliable(record)


func _poll_authenticated_peers() -> void:
	for record in _authenticated_peers.duplicate():
		var peer: WebSocketPeer = record.peer
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_authenticated_peers.erase(record)
			continue
		if peer.get_available_packet_count() > MAX_RELIABLE_MESSAGES:
			_authenticated_peers.erase(record)
			_close_record(record, "too many queued packets")
			continue
		var failed := false
		while peer.get_available_packet_count() > 0:
			var packet: PackedByteArray = peer.get_packet()
			if not peer.was_string_packet() or packet.size() > MAX_MESSAGE_BYTES:
				failed = true
				break
			var ping_result := validate_ping_message(packet.get_string_from_utf8())
			if not bool(ping_result.get("ok", false)):
				failed = true
				break
			var ping_envelope: Dictionary = ping_result.envelope
			var client_sequence := _integer_value(ping_envelope.seq)
			if client_sequence <= int(record.get("client_sequence", -1)):
				failed = true
				break
			record["client_sequence"] = client_sequence
			if not _queue_identity_message(record, "pong", {"echo": ping_envelope.d}):
				failed = true
				break
		if failed:
			_authenticated_peers.erase(record)
			_close_record(record, "malformed or unbounded message")
			continue
		if not _flush_reliable(record):
			_authenticated_peers.erase(record)
			_close_record(record, "reliable send failed")


func _queue_identity_message(record: Dictionary, message_type: String, data: Dictionary) -> bool:
	var envelope_data := _identity_payload(record)
	for key in data:
		envelope_data[key] = data[key]
	var envelope := {"v": PROTOCOL_VERSION, "t": message_type, "seq": int(record.sequence) + 1, "d": envelope_data}
	var identity := _identity_snapshot()
	if identity.has("tick") and typeof(identity.tick) == TYPE_INT and int(identity.tick) >= 0:
		envelope["tick"] = int(identity.tick)
	record["sequence"] = envelope.seq
	return _queue_reliable(record, envelope)


func _identity_payload(record: Dictionary) -> Dictionary:
	var identity := _identity_snapshot()
	return {
		"peer": "gsp-peer-%d" % int(record.id),
		"process": OS.get_process_id(),
		"process_id": OS.get_process_id(),
		"vehicle_instance": String(identity.get("vehicle_instance", "")),
		"authority": String(identity.get("authority", "unavailable")),
		"registry": identity.get("registry", {}),
	}


func _identity_snapshot() -> Dictionary:
	if _identity_provider.is_valid():
		var provided = _identity_provider.call()
		if typeof(provided) == TYPE_DICTIONARY:
			return provided
	return {}


func _queue_reliable(record: Dictionary, envelope: Dictionary) -> bool:
	var serialized := JSON.stringify(envelope)
	var serialized_bytes := serialized.to_utf8_buffer().size()
	var queue: Array = record.get("reliable_queue", [])
	var queued_bytes := int(record.get("reliable_bytes", 0))
	if queue.size() >= MAX_RELIABLE_MESSAGES or queued_bytes + serialized_bytes > MAX_RELIABLE_BYTES:
		reliable_overflow_count += 1
		last_reliable_error = "reliable queue overflow"
		_close_record(record, last_reliable_error)
		return false
	queue.append(serialized)
	record["reliable_queue"] = queue
	record["reliable_bytes"] = queued_bytes + serialized_bytes
	return true


func _flush_reliable(record: Dictionary) -> bool:
	var peer: WebSocketPeer = record.peer
	var queue: Array = record.get("reliable_queue", [])
	while not queue.is_empty():
		var serialized := String(queue[0])
		if peer.send_text(serialized) != OK:
			reliable_send_failure_count += 1
			last_reliable_error = "reliable send failed"
			_close_record(record, last_reliable_error)
			return false
		queue.pop_front()
		record["reliable_bytes"] = maxi(0, int(record.get("reliable_bytes", 0)) - serialized.to_utf8_buffer().size())
		record["reliable_queue"] = queue
	return true


func _close_record(record: Dictionary, reason: String) -> void:
	record["closed"] = true
	var peer: WebSocketPeer = record.get("peer")
	if peer == null or peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return
	peer.close(1008, reason.substr(0, 120))


func _exit_tree() -> void:
	stop()
