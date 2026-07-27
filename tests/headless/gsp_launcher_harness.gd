extends SceneTree

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")

var _stop_path := ""
var _launcher: GspLauncher


func _init() -> void:
    var args := OS.get_cmdline_user_args()
    _stop_path = _argument(args, "--stop-file")
    if _stop_path.is_empty():
        push_error("GSP launcher harness requires --stop-file")
        quit(2)
        return
    _launcher = GspLauncher.new()
    get_root().add_child(_launcher)
    var result := _launcher.launch({
        "enabled": true,
        "open": true,
        "display_name": "Wayland",
        "open_panel": Callable(self, "_open_panel"),
    })
    if not bool(result.get("ok", false)):
        push_error(String(result.get("error", "GSP launcher failed")))
        quit(1)


func _process(_delta: float) -> bool:
    if FileAccess.file_exists(_stop_path):
        DirAccess.remove_absolute(_stop_path)
        _launcher.free()
        quit(0)
    return false


func _argument(args: Array[String], name: String) -> String:
    var index := args.find(name)
    return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""


func _open_panel(_url: String) -> bool:
    return true
