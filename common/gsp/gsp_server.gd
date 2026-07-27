extends Node
class_name GspServer

const BIND_ADDRESS := "127.0.0.1"
const PORT_RANGE: Array[int] = [8765, 8766, 8767, 8768, 8769]
const PROTOCOL_VERSION := 2
const MAX_PROTOCOL_INTEGER := 9_007_199_254_740_991
const TOKEN_BYTES := 16
const MAX_LIVE_PEERS := 8
const MAX_AUTHENTICATED_PEERS := 2
const MAX_PENDING_HANDSHAKES := 8
const MAX_UNAUTHENTICATED_PEERS := 8
const PENDING_HANDSHAKE_TIMEOUT_MS := 5_000
const OPEN_UNAUTHENTICATED_TIMEOUT_MS := 2_000
const CLOSING_PEER_TIMEOUT_MS := 1_000
const MAX_MESSAGE_BYTES := 16_384
const MAX_STRING_BYTES := 2_048
const MAX_VALUE_DEPTH := 32
const MAX_RELIABLE_MESSAGES := 64
const MAX_RELIABLE_BYTES := 65_536
const NATIVE_OUTBOUND_BUFFER_BYTES := MAX_RELIABLE_BYTES + MAX_MESSAGE_BYTES
const MAX_NATIVE_QUEUED_PACKETS := MAX_RELIABLE_MESSAGES + 16

var reliable_overflow_count := 0
var reliable_send_failure_count := 0
var last_reliable_error := ""

var _tcp_server := TCPServer.new()
var _pending_handshakes: Array[Dictionary] = []
var _unauthenticated_peers: Array[Dictionary] = []
var _authenticated_peers: Array[Dictionary] = []
var _closing_peers: Array[Dictionary] = []
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
	for record in _pending_handshakes.duplicate():
		_begin_close(record, "server stopped")
	for record in _unauthenticated_peers.duplicate():
		_begin_close(record, "server stopped")
	for record in _authenticated_peers.duplicate():
		_begin_close(record, "server stopped")
	for record in _closing_peers:
		var peer: WebSocketPeer = record.get("peer")
		if peer != null:
			peer.close()
	_pending_handshakes.clear()
	_unauthenticated_peers.clear()
	_authenticated_peers.clear()
	_closing_peers.clear()
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


func get_live_peer_count() -> int:
	return _pending_handshakes.size() + _unauthenticated_peers.size() + _authenticated_peers.size() + _closing_peers.size()


func get_pending_handshake_count() -> int:
	return _pending_handshakes.size()


func get_unauthenticated_peer_count() -> int:
	return _unauthenticated_peers.size()


func get_authenticated_peer_count() -> int:
	return _authenticated_peers.size()


func get_closing_peer_count() -> int:
	return _closing_peers.size()


func get_peer_transport_diagnostics() -> Array[Dictionary]:
	var diagnostics: Array[Dictionary] = []
	for record in _pending_handshakes + _unauthenticated_peers + _authenticated_peers + _closing_peers:
		var peer: WebSocketPeer = record.get("peer")
		if peer == null:
			continue
		diagnostics.append({
			"state": peer.get_ready_state(),
			"outbound_buffered_bytes": peer.get_current_outbound_buffered_amount(),
			"reliable_queue_count": record.get("reliable_queue", []).size(),
			"reliable_queue_bytes": int(record.get("reliable_bytes", 0)),
		})
	return diagnostics


func set_identity_provider(provider: Callable) -> void:
	_identity_provider = provider


func poll() -> void:
	if not _running:
		return
	_accept_connections()
	_poll_pending_handshakes()
	_poll_unauthenticated_peers()
	_poll_authenticated_peers()
	_poll_closing_peers()


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
	if int(envelope.seq) != 0:
		return {"ok": false, "error": "auth sequence must be zero"}
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
	if not _validate_value_bounds(parsed, 0):
		return {"ok": false, "error": "application value is unbounded"}
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
		if value >= 0 and value <= MAX_PROTOCOL_INTEGER:
			return int(value)
		return -1
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= float(MAX_PROTOCOL_INTEGER) and float(value) == floor(float(value)):
		return int(value)
	return -1


static func _validate_value_bounds(value: Variant, depth: int) -> bool:
	if depth > MAX_VALUE_DEPTH:
		return false
	match typeof(value):
		TYPE_STRING:
			return String(value).to_utf8_buffer().size() <= MAX_STRING_BYTES
		TYPE_ARRAY:
			for item in value:
				if not _validate_value_bounds(item, depth + 1):
					return false
		TYPE_DICTIONARY:
			for key in value:
				if typeof(key) != TYPE_STRING or String(key).to_utf8_buffer().size() > MAX_STRING_BYTES:
					return false
				if not _validate_value_bounds(value[key], depth + 1):
					return false
	return true


func _accept_connections() -> void:
	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		if stream == null:
			break
		if get_live_peer_count() >= MAX_LIVE_PEERS or _pending_handshakes.size() >= MAX_PENDING_HANDSHAKES or _unauthenticated_peers.size() >= MAX_UNAUTHENTICATED_PEERS:
			stream.disconnect_from_host()
			continue
		if _authenticated_peers.size() >= MAX_AUTHENTICATED_PEERS:
			stream.disconnect_from_host()
			continue
		var websocket := WebSocketPeer.new()
		websocket.inbound_buffer_size = MAX_MESSAGE_BYTES
		websocket.outbound_buffer_size = NATIVE_OUTBOUND_BUFFER_BYTES
		websocket.max_queued_packets = MAX_NATIVE_QUEUED_PACKETS
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
			_begin_close(record, "handshake timeout")
			continue
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_pending_handshakes.erase(record)
			if _unauthenticated_peers.size() >= MAX_UNAUTHENTICATED_PEERS:
				_begin_close(record, "unauthenticated peer limit")
				continue
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
			_begin_close(record, "authentication timeout")
			continue
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN or peer.get_available_packet_count() == 0:
			continue
		var packet: PackedByteArray = peer.get_packet()
		if not peer.was_string_packet() or packet.size() > MAX_MESSAGE_BYTES:
			_unauthenticated_peers.erase(record)
			_begin_close(record, "authentication required")
			continue
		var auth_result := validate_auth_message(packet.get_string_from_utf8(), _token)
		if not bool(auth_result.get("ok", false)):
			_unauthenticated_peers.erase(record)
			_begin_close(record, "authentication rejected")
			continue
		_unauthenticated_peers.erase(record)
		if _authenticated_peers.size() >= MAX_AUTHENTICATED_PEERS or get_live_peer_count() >= MAX_LIVE_PEERS:
			_begin_close(record, "authenticated peer limit")
			continue
		record["state"] = "authenticated"
		record["reliable_queue"] = []
		record["reliable_bytes"] = 0
		record["sequence"] = 0
		record["client_sequence"] = int(auth_result.get("seq", -1))
		_authenticated_peers.append(record)
		if not _queue_identity_message(record, "hello", {}):
			_authenticated_peers.erase(record)
			_begin_close(record, "reliable send failed")
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
			_begin_close(record, "too many queued packets")
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
			if client_sequence != int(record.get("client_sequence", -1)) + 1:
				failed = true
				break
			record["client_sequence"] = client_sequence
			if not _queue_identity_message(record, "pong", {"echo": ping_envelope.d}):
				failed = true
				break
		if failed:
			_authenticated_peers.erase(record)
			_begin_close(record, "malformed or unbounded message")
			continue
		if not _flush_reliable(record):
			_authenticated_peers.erase(record)
			_begin_close(record, "reliable send failed")


func _queue_identity_message(record: Dictionary, message_type: String, data: Dictionary) -> bool:
	var next_sequence := int(record.sequence) + 1
	var envelope_data := _identity_payload(record, next_sequence)
	for key in data:
		envelope_data[key] = data[key]
	var envelope := {"v": PROTOCOL_VERSION, "t": message_type, "seq": next_sequence, "d": envelope_data}
	var identity := _identity_snapshot()
	if identity.has("tick") and typeof(identity.tick) == TYPE_INT and int(identity.tick) >= 0:
		envelope["tick"] = int(identity.tick)
	if not _queue_reliable(record, envelope):
		return false
	record["sequence"] = next_sequence
	return true


func _identity_payload(record: Dictionary, sequence: int) -> Dictionary:
	var identity := _identity_snapshot()
	var pid := int(identity.get("pid", OS.get_process_id()))
	var instance_name := String(identity.get("instance_name", identity.get("vehicle_instance", "unavailable")))
	return {
		"sim_version": String(identity.get("sim_version", ProjectSettings.get_setting("application/config/version", "unavailable"))),
		"proto_v": PROTOCOL_VERSION,
		"physics_hz": int(identity.get("physics_hz", Engine.physics_ticks_per_second)),
		"pid": pid,
		"instance_name": instance_name,
		"registry_hash": String(identity.get("registry_hash", "unavailable")),
		"peer": "gsp-peer-%d" % int(record.id),
		"process": pid,
		"process_id": pid,
		"vehicle_instance": String(identity.get("vehicle_instance", instance_name)),
		"authority": String(identity.get("authority", "unavailable")),
		"registry": identity.get("registry", {}),
		"sequence": sequence,
		"server_sequence": sequence,
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
	var peer: WebSocketPeer = record.peer
	var native_buffered_bytes := maxi(0, peer.get_current_outbound_buffered_amount())
	if queue.size() >= MAX_RELIABLE_MESSAGES or queued_bytes + native_buffered_bytes + serialized_bytes > MAX_RELIABLE_BYTES:
		reliable_overflow_count += 1
		last_reliable_error = "reliable queue overflow"
		_begin_close(record, last_reliable_error)
		return false
	queue.append(serialized)
	record["reliable_queue"] = queue
	record["reliable_bytes"] = queued_bytes + serialized_bytes
	return true


func _flush_reliable(record: Dictionary) -> bool:
	var peer: WebSocketPeer = record.peer
	var queue: Array = record.get("reliable_queue", [])
	while not queue.is_empty():
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			return false
		var serialized := String(queue[0])
		if peer.send_text(serialized) != OK:
			reliable_send_failure_count += 1
			last_reliable_error = "reliable send failed"
			_begin_close(record, last_reliable_error)
			return false
		queue.pop_front()
		record["reliable_bytes"] = maxi(0, int(record.get("reliable_bytes", 0)) - serialized.to_utf8_buffer().size())
		record["reliable_queue"] = queue
	return true

func _begin_close(record: Dictionary, reason: String) -> void:
	if bool(record.get("closing", false)):
		return
	_remove_from_active_sets(record)
	record["closing"] = true
	record["close_deadline_ms"] = Time.get_ticks_msec() + CLOSING_PEER_TIMEOUT_MS
	record["close_reason"] = reason
	_closing_peers.append(record)
	var peer: WebSocketPeer = record.get("peer")
	if peer != null and peer.get_ready_state() != WebSocketPeer.STATE_CLOSED and record.get("reliable_queue", []).is_empty():
		peer.close(1008, reason.substr(0, 120))


func _remove_from_active_sets(record: Dictionary) -> void:
	_pending_handshakes.erase(record)
	_unauthenticated_peers.erase(record)
	_authenticated_peers.erase(record)


func _poll_closing_peers() -> void:
	for record in _closing_peers.duplicate():
		var peer: WebSocketPeer = record.get("peer")
		if peer == null:
			_closing_peers.erase(record)
			continue
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_closing_peers.erase(record)
			continue
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN and not record.get("reliable_queue", []).is_empty():
			if not _flush_reliable(record):
				peer.close(1008, String(record.get("close_reason", "reliable close")).substr(0, 120))
				continue
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN and record.get("reliable_queue", []).is_empty():
			peer.close(1008, String(record.get("close_reason", "closing")).substr(0, 120))
			continue
		if Time.get_ticks_msec() >= int(record.get("close_deadline_ms", 0)):
			peer.close(-1)
			_closing_peers.erase(record)


func _exit_tree() -> void:
	stop()
