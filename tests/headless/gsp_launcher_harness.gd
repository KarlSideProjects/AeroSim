extends SceneTree

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")

class LauncherHarness extends GspLauncher:
    var open_invoked := false

    func get_display_name() -> String:
        return "Wayland"

    func open_panel(_url: String) -> bool:
        open_invoked = true
        return true


var _stop_path := ""
var _launcher: LauncherHarness


func _init() -> void:
    var args := OS.get_cmdline_user_args()
    _stop_path = _argument(args, "--stop-file")
    if _stop_path.is_empty():
        push_error("GSP launcher harness requires --stop-file")
        quit(2)
        return
    _launcher = LauncherHarness.new()
    get_root().add_child(_launcher)
    var result := _launcher.launch({
        "enabled": true,
        "open": true,
    })
    if not bool(result.get("ok", false)):
        push_error(String(result.get("error", "GSP launcher failed")))
        quit(1)
        return
    if not _launcher.open_invoked:
        push_error("GSP launcher did not invoke the requested panel opener")
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
