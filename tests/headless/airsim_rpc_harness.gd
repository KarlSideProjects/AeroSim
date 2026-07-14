extends SceneTree

const AirSimRpcServer = preload("res://common/rpc/airsim_rpc_server.gd")

var server: AirSimRpcServer
var stop_file := ""


func _init() -> void:
    var args := OS.get_cmdline_user_args()
    var port := AirSimRpcServer.DEFAULT_PORT
    for index in range(args.size() - 1):
        if args[index] == "--rpc-port":
            port = int(args[index + 1])
        elif args[index] == "--ready-file":
            _ready_file = args[index + 1]
        elif args[index] == "--stop-file":
            stop_file = args[index + 1]

    server = AirSimRpcServer.new()
    root.add_child(server)
    var result: Dictionary = server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": port,
        "RpcEnabled": true,
    })
    if not result.ok:
        push_error("RPC harness failed to start: %s" % result.error)
        quit(1)
        return
    if not _ready_file.is_empty():
        var ready := FileAccess.open(_ready_file, FileAccess.WRITE)
        if ready == null:
            push_error("RPC harness could not write ready file")
            quit(1)
            return
        ready.store_string("ready")
        ready.close()


var _ready_file := ""


func _process(_delta: float) -> bool:
    if not stop_file.is_empty() and FileAccess.file_exists(stop_file):
        server.stop()
        quit()
    return false
