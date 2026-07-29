extends Node
class_name GspLauncher

const PANEL_RESOURCE_PATH := "res://common/gsp/gsp_panel.html"
const PANEL_DIRECTORY := "gsp"
const DEMO_BROWSER_EXECUTABLE := "google-chrome"
const DEMO_BROWSER_CLASS := "AeroSimGspDemo"
const PANEL_ASSET_PATHS := [
    "res://common/gsp/assets/gsp_visual.js",
    "res://common/gsp/assets/three-0.180.0.global.min.js",
]
const GspServer = preload("res://common/gsp/gsp_server.gd")

var _server: GspServer
var _panel_url := ""


func _ready() -> void:
    pass


static func file_uri(path: String) -> String:
    var normalized := path.replace("\\", "/")
    var encoded_parts: Array[String] = []
    for part in normalized.split("/", false):
        encoded_parts.append(part.uri_encode())
    var encoded_path := "/".join(encoded_parts)
    if normalized.begins_with("/"):
        return "file:///" + encoded_path
    return "file://" + encoded_path


static func panel_url(panel_file_url: String, port: int, token: String) -> String:
    return "%s#port=%d&token=%s" % [panel_file_url, port, token]


func launch(options: Dictionary = {}) -> Dictionary:
    var open_requested := bool(options.get("open", false))
    if not OS.is_debug_build():
        return {"ok": false, "error": "GSP requires a debug build"}
    if is_panel_ready():
        var opened := open_panel(_panel_url) if open_requested else true
        var shell_result := shell_open_result(open_requested, opened, _panel_url)
        return {
            "ok": bool(shell_result.get("ok", false)),
            "enabled": true,
            "opened": opened,
            "panel_url": _panel_url,
            "gsp_running": true,
            "error": shell_result.get("error", ""),
        }

    _discard_unready_server()
    DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
    DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
    _server = GspServer.new()
    add_child(_server)
    if get_parent() != null and get_parent().has_method("gsp_identity_snapshot"):
        _server.set_identity_provider(Callable(get_parent(), "gsp_identity_snapshot"))
    if get_parent() != null and get_parent().has_method("gsp_telemetry_snapshot"):
        _server.set_telemetry_provider(Callable(get_parent(), "gsp_telemetry_snapshot"))
    if get_parent() != null and get_parent().has_method("gsp_tuning_request"):
        _server.set_tuning_request_provider(Callable(get_parent(), "gsp_tuning_request"))
    if get_parent() != null and get_parent().has_method("gsp_tuning_results"):
        _server.set_tuning_result_provider(Callable(get_parent(), "gsp_tuning_results"))
    if get_parent() != null and get_parent().has_method("gsp_quick_adjust_request"):
        _server.set_quick_adjust_request_provider(Callable(get_parent(), "gsp_quick_adjust_request"))
    if get_parent() != null and get_parent().has_method("gsp_preset_request"):
        _server.set_preset_request_provider(Callable(get_parent(), "gsp_preset_request"))
    if get_parent() != null and get_parent().has_method("gsp_marker_request"):
        _server.set_marker_request_provider(Callable(get_parent(), "gsp_marker_request"))
    if get_parent() != null and get_parent().has_method("gsp_simulation_request"):
        _server.set_simulation_request_provider(Callable(get_parent(), "gsp_simulation_request"))
    var server_result := _server.start()
    if not bool(server_result.get("ok", false)):
        print("GSP unavailable: %s" % String(server_result.get("error", "listener failed")))
        _discard_unready_server()
        return {"ok": false, "gsp_running": false, "error": server_result.get("error", "listener failed")}

    var installed := install_panel(OS.get_user_data_dir())
    if not bool(installed.get("ok", false)):
        _discard_unready_server()
        return installed
    var url := panel_url(file_uri(String(installed.path)), int(server_result.port), String(server_result.token))
    _panel_url = url
    print("GSP panel URL: %s" % url)
    var opened := true
    if open_requested:
        opened = open_panel(url)
    var shell_result: Dictionary = shell_open_result(open_requested, opened, url)
    var result := {
        "ok": bool(shell_result.get("ok", false)),
        "enabled": true,
        "display_name": get_display_name(),
        "window_mode": DisplayServer.window_get_mode(),
        "borderless": DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS),
        "panel_path": installed.path,
        "panel_url": url,
        "opened": opened,
        "panel_hash": installed.hash,
        "gsp_running": true,
        "gsp_port": server_result.port,
    }
    if not bool(shell_result.get("ok", false)):
        result["error"] = shell_result.get("error", "OS.shell_open failed")
    return result


func _exit_tree() -> void:
    _discard_unready_server()
    _panel_url = ""


func _discard_unready_server() -> void:
    if _server != null:
        _server.stop()
        _server.queue_free()
        _server = null


func get_display_name() -> String:
    return DisplayServer.get_name()


func open_panel(url: String) -> bool:
    return OS.shell_open(url) == OK


func is_panel_ready() -> bool:
    return _server != null and not _panel_url.is_empty()


func request_panel_open() -> Dictionary:
    if not is_panel_ready():
        return launch({"open": true})
    return shell_open_result(true, open_panel(_panel_url), _panel_url)


func open_demo_panel() -> Dictionary:
    var game_position := DisplayServer.window_get_position()
    var game_size := DisplayServer.window_get_size()
    var launch_result := launch({"open": false}) if not is_panel_ready() else {"ok": true, "panel_url": _panel_url}
    if not bool(launch_result.get("ok", false)):
        return launch_result
    if DisplayServer.get_name() != "X11":
        return shell_open_result(true, open_panel(_panel_url), _panel_url)
    var game_height := game_size.y * 3 / 5
    DisplayServer.window_set_position(game_position)
    DisplayServer.window_set_size(Vector2i(game_size.x, game_height))
    var browser_profile := OS.get_user_data_dir().path_join(PANEL_DIRECTORY).path_join("demo-browser")
    var browser_pid := OS.create_process(DEMO_BROWSER_EXECUTABLE, [
        "--no-first-run", "--user-data-dir=%s" % browser_profile,
        "--class=%s" % DEMO_BROWSER_CLASS, "--app=%s" % _panel_url,
    ])
    if browser_pid <= 0:
        return shell_open_result(true, open_panel(_panel_url), _panel_url)
    OS.create_process("xdotool", [
        "search", "--sync", "--onlyvisible", "--class", DEMO_BROWSER_CLASS,
        "windowmove", str(game_position.x), str(game_position.y + game_height),
        "windowsize", str(game_size.x), str(game_size.y - game_height),
    ])
    return {"ok": true, "opened": true, "panel_url": _panel_url, "split": true}


func copy_panel_url() -> Dictionary:
    if not is_panel_ready():
        var launch_result := launch({"open": false})
        if not bool(launch_result.get("ok", false)):
            return launch_result
    DisplayServer.clipboard_set(_panel_url)
    return {"ok": true}


static func shell_open_result(open_requested: bool, opened: bool, _url: String) -> Dictionary:
    if open_requested and not opened:
        return {"ok": false, "error": "OS.shell_open failed; panel was not opened"}
    return {"ok": true}


func install_panel(data_directory: String) -> Dictionary:
    var source_file := FileAccess.open(PANEL_RESOURCE_PATH, FileAccess.READ)
    if source_file == null:
        return {"ok": false, "error": "packaged panel is unavailable"}
    var source := source_file.get_as_text()
    var hash_context := HashingContext.new()
    hash_context.start(HashingContext.HASH_SHA256)
    hash_context.update(source.to_utf8_buffer())
    var assets: Array[Dictionary] = []
    for source_path in PANEL_ASSET_PATHS:
        var asset_file := FileAccess.open(source_path, FileAccess.READ)
        if asset_file == null:
            return {"ok": false, "error": "packaged panel asset is unavailable: %s" % source_path}
        var content := asset_file.get_buffer(asset_file.get_length())
        asset_file.close()
        hash_context.update(content)
        assets.append({"name": source_path.get_file(), "content": content})
    var panel_hash := hash_context.finish().hex_encode()
    var directory := data_directory.path_join(PANEL_DIRECTORY)
    var bundle := directory.path_join("bundle-%s" % panel_hash)
    var target := bundle.path_join("panel.html")
    var mkdir_error := DirAccess.make_dir_recursive_absolute(directory)
    if mkdir_error != OK:
        return {"ok": false, "error": "cannot create panel directory: %s" % mkdir_error}

    if not FileAccess.file_exists(target):
        var temporary_bundle := bundle + ".tmp-%d" % Time.get_ticks_usec()
        var assets_directory := temporary_bundle.path_join("assets")
        if DirAccess.make_dir_recursive_absolute(assets_directory) != OK:
            return {"ok": false, "error": "cannot create temporary panel bundle"}
        var temporary_file := FileAccess.open(temporary_bundle.path_join("panel.html"), FileAccess.WRITE)
        if temporary_file == null:
            return {"ok": false, "error": "cannot write temporary panel"}
        temporary_file.store_string(source)
        temporary_file.flush()
        temporary_file.close()
        for asset in assets:
            var asset_file := FileAccess.open(assets_directory.path_join(String(asset.name)), FileAccess.WRITE)
            if asset_file == null:
                DirAccess.remove_absolute(temporary_bundle)
                return {"ok": false, "error": "cannot write temporary panel asset"}
            asset_file.store_buffer(asset.content)
            asset_file.flush()
            asset_file.close()
        var rename_error := DirAccess.rename_absolute(temporary_bundle, bundle)
        if rename_error != OK and not FileAccess.file_exists(target):
            DirAccess.remove_absolute(temporary_bundle)
            return {"ok": false, "error": "cannot atomically install panel: %s" % rename_error}
    return {"ok": true, "path": target, "hash": panel_hash}
