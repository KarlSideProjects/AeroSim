extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _ready_path := ""
var _stop_path := ""


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_ready_path = _argument(args, "--ready-file")
	_stop_path = _argument(args, "--stop-file")
	if _ready_path.is_empty() or _stop_path.is_empty():
		push_error("GSP server harness requires --ready-file and --stop-file")
		quit(2)
		return
	_server = GspServer.new()
	get_root().add_child(_server)
	var started := _server.start()
	if not bool(started.get("ok", false)):
		push_error(String(started.get("error", "GSP server failed to start")))
		quit(1)
		return
	var ready := FileAccess.open(_ready_path, FileAccess.WRITE)
	if ready == null:
		push_error("cannot write GSP harness readiness file")
		quit(1)
		return
	ready.store_string(JSON.stringify({"port": started.port, "token": started.token, "listening": _server.is_listening()}))
	ready.close()


func _process(_delta: float) -> bool:
	if FileAccess.file_exists(_stop_path):
		_server.stop()
		quit(0)
	return false


func _argument(args: Array[String], name: String) -> String:
	var index := args.find(name)
	return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""
