extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _ready_path := ""
var _stop_path := ""
var _status_path := ""
var _probe_path := ""
var _probe_sequence := 0
var _max_closing_peer_count := 0
var _large_identity := false
var _process_ticks := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_ready_path = _argument(args, "--ready-file")
	_stop_path = _argument(args, "--stop-file")
	_status_path = _argument(args, "--status-file")
	_probe_path = _argument(args, "--probe-file")
	_large_identity = args.has("--large-identity")
	if _ready_path.is_empty() or _stop_path.is_empty():
		push_error("GSP server harness requires --ready-file and --stop-file")
		quit(2)
		return
	_server = GspServer.new()
	get_root().add_child(_server)
	_server.set_identity_provider(Callable(self, "_identity"))
	var started := _server.start()
	if not bool(started.get("ok", false)):
		push_error(String(started.get("error", "GSP server failed to start")))
		quit(1)
		return
	var temporary_path := "%s.tmp-%d" % [_ready_path, Time.get_ticks_usec()]
	var ready := FileAccess.open(temporary_path, FileAccess.WRITE)
	if ready == null:
		push_error("cannot write GSP harness readiness file")
		quit(1)
		return
	ready.store_string(JSON.stringify({
		"port": started.port,
		"token": started.token,
		"listening": _server.is_listening(),
		"max_pending_handshakes": GspServer.MAX_PENDING_HANDSHAKES,
		"closing_peer_timeout_ms": GspServer.CLOSING_PEER_TIMEOUT_MS,
	}))
	ready.flush()
	ready.close()
	if DirAccess.rename_absolute(temporary_path, _ready_path) != OK:
		DirAccess.remove_absolute(temporary_path)
		push_error("cannot publish GSP harness readiness file")
		quit(1)


func _process(_delta: float) -> bool:
	_process_ticks += 1
	_max_closing_peer_count = maxi(_max_closing_peer_count, _server.get_closing_peer_count())
	if not _probe_path.is_empty() and FileAccess.file_exists(_probe_path):
		DirAccess.remove_absolute(_probe_path)
		_probe_sequence += 1
		_write_status(_status_snapshot())
	if FileAccess.file_exists(_stop_path):
		var snapshot := _status_snapshot()
		_server.stop()
		snapshot["after_stop_live_peer_count"] = _server.get_live_peer_count()
		_write_status(snapshot)
		quit(0)
	return false


func _status_snapshot() -> Dictionary:
	return {
		"timestamp_ms": Time.get_ticks_msec(),
		"probe_sequence": _probe_sequence,
		"reliable_overflow_count": _server.reliable_overflow_count,
		"reliable_send_failure_count": _server.reliable_send_failure_count,
		"last_reliable_error": _server.last_reliable_error,
		"live_peer_count": _server.get_live_peer_count(),
		"authenticated_peer_count": _server.get_authenticated_peer_count(),
		"closing_peer_count": _server.get_closing_peer_count(),
		"max_closing_peer_count": _max_closing_peer_count,
		"process_ticks": _process_ticks,
		"physics_ticks": Engine.get_physics_frames(),
		"peer_transport_diagnostics": _server.get_peer_transport_diagnostics(),
	}


func _write_status(snapshot: Dictionary) -> void:
	if _status_path.is_empty():
		return
	var status := FileAccess.open(_status_path, FileAccess.WRITE)
	if status == null:
		return
	status.store_string(JSON.stringify(snapshot))
	status.flush()
	status.close()


func _argument(args: Array[String], name: String) -> String:
	var index := args.find(name)
	return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""


func _identity() -> Dictionary:
	var registry := {"vehicle_instances": ["Drone1"]}
	if _large_identity:
		for key in ["a", "b", "c", "d", "e", "f", "g"]:
			registry[key] = "x".repeat(1_500)
	return {
		"sim_version": "fixture-1",
		"proto_v": 2,
		"physics_hz": 240,
		"pid": OS.get_process_id(),
		"instance_name": "Drone1",
		"vehicle_instance": "Drone1",
		"authority": "fixture",
		"registry": registry,
		"registry_hash": "unavailable",
	}
