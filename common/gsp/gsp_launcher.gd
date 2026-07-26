extends Node
class_name GspLauncher

const ENABLE_ARG := "--aerosim-gsp"
const NO_OPEN_ARG := "--aerosim-gsp-no-open"
const PANEL_RESOURCE_PATH := "res://common/gsp/gsp_panel.html"
const PANEL_DIRECTORY := "gsp"


func _ready() -> void:
	var options := parse_user_args(OS.get_cmdline_user_args())
	if not bool(options.get("enabled", false)):
		return
	var result := launch(options)
	if not bool(result.get("ok", false)):
		push_error("GSP launch failed: %s" % String(result.get("error", "unknown error")))


static func parse_user_args(args: Array[String]) -> Dictionary:
	var enabled := args.has(ENABLE_ARG)
	return {
		"enabled": enabled,
		"open": enabled and not args.has(NO_OPEN_ARG),
	}


static func is_native_wayland(display_name: String) -> bool:
	return display_name == "Wayland"


static func file_uri(path: String) -> String:
	var normalized := path.replace("\\", "/")
	var encoded_parts: Array[String] = []
	for part in normalized.split("/", false):
		encoded_parts.append(part.uri_encode())
	var encoded_path := "/".join(encoded_parts)
	if normalized.begins_with("/"):
		return "file:///" + encoded_path
	return "file://" + encoded_path


func launch(options: Dictionary = {}) -> Dictionary:
	var launch_options := options
	if launch_options.is_empty():
		launch_options = parse_user_args(OS.get_cmdline_user_args())
	if not bool(launch_options.get("enabled", false)):
		return {"ok": true, "enabled": false}

	var display_name := DisplayServer.get_name()
	if not is_native_wayland(display_name):
		return {"ok": false, "enabled": true, "error": "native Wayland required; detected %s" % display_name}

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)

	var installed := install_panel(OS.get_user_data_dir())
	if not bool(installed.get("ok", false)):
		return installed
	var url := file_uri(String(installed.path))
	var open_requested := bool(launch_options.get("open", false))
	var opened := true
	if open_requested:
		opened = open_panel(url)
	if not open_requested or not opened:
		print("GSP panel URL: %s" % url)
	var shell_result: Dictionary = shell_open_result(open_requested, opened, url)
	var result := {
		"ok": bool(shell_result.get("ok", false)),
		"enabled": true,
		"display_name": display_name,
		"window_mode": DisplayServer.window_get_mode(),
		"borderless": DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS),
		"panel_path": installed.path,
		"panel_url": url,
		"opened": opened,
		"panel_hash": installed.hash,
	}
	if not bool(shell_result.get("ok", false)):
		result["error"] = shell_result.get("error", "OS.shell_open failed")
	return result


func open_panel(url: String) -> bool:
	return OS.shell_open(url) == OK


static func shell_open_result(open_requested: bool, opened: bool, url: String) -> Dictionary:
	if open_requested and not opened:
		return {"ok": false, "error": "OS.shell_open failed for panel URL: %s" % url}
	return {"ok": true}


func install_panel(data_directory: String) -> Dictionary:
	var source_file := FileAccess.open(PANEL_RESOURCE_PATH, FileAccess.READ)
	if source_file == null:
		return {"ok": false, "error": "packaged panel is unavailable"}
	var source := source_file.get_as_text()
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(source.to_utf8_buffer())
	var panel_hash := hash_context.finish().hex_encode()
	var directory := data_directory.path_join(PANEL_DIRECTORY)
	var target := directory.path_join("panel-%s.html" % panel_hash)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(directory)
	if mkdir_error != OK:
		return {"ok": false, "error": "cannot create panel directory: %s" % mkdir_error}

	if not FileAccess.file_exists(target):
		var temporary := target + ".tmp-%d" % Time.get_ticks_usec()
		var temporary_file := FileAccess.open(temporary, FileAccess.WRITE)
		if temporary_file == null:
			return {"ok": false, "error": "cannot write temporary panel"}
		temporary_file.store_string(source)
		temporary_file.flush()
		temporary_file.close()
		var rename_error := DirAccess.rename_absolute(temporary, target)
		if rename_error != OK and not FileAccess.file_exists(target):
			DirAccess.remove_absolute(temporary)
			return {"ok": false, "error": "cannot atomically install panel: %s" % rename_error}
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(temporary)

	return {"ok": true, "path": target, "hash": panel_hash}
