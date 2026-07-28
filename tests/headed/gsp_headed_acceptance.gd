extends SceneTree

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")

var _failures: Array[String] = []
var _out_dir := "build/gsp-headed"
var _stage_path := ""
var _external_unavailable_path := ""
var _browser_click_sent_path := ""
var _pointer_inside := false
var _awaiting_panel_focus := false
var _awaiting_game_focus := false
var _panel_focus_out_observed := false
var _focus_steps: Array[String] = []
var _stage_history: Array[String] = []
var _owned_launcher: Node = null


func _initialize() -> void:
    _parse_args()
    call_deferred("_run")


static func hidpi_qualification(scale_factor: float) -> Dictionary:
    if scale_factor < 2.0:
        return {"status": "environment_not_qualified", "exit_code": 2, "scale_factor": scale_factor}
    return {"status": "qualified", "exit_code": 0, "scale_factor": scale_factor}


static func environment_qualification(scale_factor: float, input_automation_available: bool) -> Dictionary:
    if scale_factor < 2.0 or not input_automation_available:
        return {
            "status": "environment_not_qualified",
            "exit_code": 2,
            "scale_factor": scale_factor,
            "input_automation_available": input_automation_available,
        }
    return {
        "status": "qualified",
        "exit_code": 0,
        "scale_factor": scale_factor,
        "input_automation_available": true,
    }


static func observed_focus_steps(current_steps: Array[String], event: String, pointer_inside: bool, window_focused: bool, external_click_sent: bool) -> Array[String]:
    var steps := current_steps.duplicate()
    if event == "focus_out" and steps == ["capture", "release"] and external_click_sent:
        steps.append("panel_focus")
    elif event == "focus_in" and steps == ["capture", "release", "panel_focus"] and pointer_inside and window_focused and not external_click_sent:
        steps.append("game_focus")
    return steps


static func append_stage(history: Array[String], stage: String) -> Array[String]:
    var stages := history.duplicate()
    if not stages.has(stage):
        stages.append(stage)
    return stages


static func stage_observed(history: Array[String], stage: String) -> bool:
    return history.has(stage)


static func terminal_outcome(status: String) -> Dictionary:
    if status == "environment_not_qualified":
        return {"message": "NOT_QUALIFIED", "exit_code": 2, "emit_failures": false}
    if status == "qualified":
        return {"message": "PASS", "exit_code": 0, "emit_failures": false}
    return {"message": "FAIL", "exit_code": 1, "emit_failures": true}


func _notification(what: int) -> void:
    if what == Node.NOTIFICATION_WM_MOUSE_ENTER:
        _pointer_inside = true
    elif what == Node.NOTIFICATION_WM_MOUSE_EXIT:
        _pointer_inside = false
    elif what == Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT and _awaiting_panel_focus:
        _panel_focus_out_observed = true
        _try_record_panel_focus()
    elif what == Node.NOTIFICATION_WM_WINDOW_FOCUS_IN and _awaiting_game_focus:
        var is_focused := DisplayServer.window_is_focused(DisplayServer.MAIN_WINDOW_ID)
        _focus_steps = observed_focus_steps(_focus_steps, "focus_in", _pointer_inside, is_focused, false)
        if _focus_steps == ["capture", "release", "panel_focus", "game_focus"]:
            _write_stage("game_focus_observed")


func _run() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://%s" % _out_dir))
    _stage_path = ProjectSettings.globalize_path("res://%s/stage.json" % _out_dir)
    _external_unavailable_path = ProjectSettings.globalize_path("res://%s/external-unavailable.json" % _out_dir)
    _browser_click_sent_path = ProjectSettings.globalize_path("res://%s/browser-click-sent.json" % _out_dir)
    if FileAccess.file_exists(_browser_click_sent_path):
        DirAccess.remove_absolute(_browser_click_sent_path)
    _owned_launcher = GspLauncher.new()
    var launch: Dictionary = _owned_launcher.launch({"enabled": true, "open": false})
    _expect(bool(launch.get("ok", false)), "GSP startup succeeds on native Wayland")
    _expect(String(launch.get("display_name", "")) == "Wayland", "GSP reports native Wayland")
    _expect(int(launch.get("window_mode", -1)) == DisplayServer.WINDOW_MODE_WINDOWED, "GSP uses windowed mode")
    _expect(bool(launch.get("borderless", false)), "GSP uses borderless windowing")
    _expect(String(launch.get("panel_url", "")).begins_with("file:///"), "GSP creates a file URL")
    if not _failures.is_empty():
        _finish("failed", 1, launch, 1.0)
        return

    # Read scale only after at least one mapped frame. Never substitute viewport scaling.
    await process_frame
    await process_frame
    var scale_factor := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
    var hidpi := hidpi_qualification(scale_factor)
    if String(hidpi.status) == "environment_not_qualified":
        _finish("environment_not_qualified", 2, launch, scale_factor, false, "compositor scale is below 2x; external input automation was unavailable")
        return

    _write_stage("await_initial_pointer")
    if not await _wait_for_initial_focus():
        _finish("environment_not_qualified", 2, launch, scale_factor, false, "external Wayland input automation or initial pointer/focus evidence was unavailable")
        return

    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    await process_frame
    _expect(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and DisplayServer.window_is_focused(DisplayServer.MAIN_WINDOW_ID), "capture follows real pointer entry and app focus")
    _focus_steps = ["capture"] if _failures.is_empty() else []
    _write_stage("captured")
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    await process_frame
    _expect(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "release returns the cursor to the compositor")
    if _failures.is_empty():
        _focus_steps.append("release")

    _awaiting_panel_focus = true
    _panel_focus_out_observed = false
    _write_stage("open_panel")
    var opened: bool = _owned_launcher.open_panel(String(launch.panel_url))
    _write_stage("panel_open_requested", {"opened": opened})
    _expect(opened, "OS.shell_open accepts the panel URL")
    if opened and _failures.is_empty():
        await _wait_for_focus_step("panel_focus")
    _awaiting_panel_focus = false

    if _focus_steps == ["capture", "release", "panel_focus"]:
        _awaiting_game_focus = true
        _write_stage("await_game_focus")
        await _wait_for_focus_step("game_focus")
        _awaiting_game_focus = false
    if _focus_steps == ["capture", "release", "panel_focus", "game_focus"]:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
        await process_frame
        _expect(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and DisplayServer.window_is_focused(DisplayServer.MAIN_WINDOW_ID), "recapture follows observed game focus and pointer return")
        if _failures.is_empty():
            _focus_steps.append("recapture")
            _write_stage("recaptured")

    if _focus_steps != ["capture", "release", "panel_focus", "game_focus", "recapture"]:
        _finish("environment_not_qualified", 2, launch, scale_factor, false, "real compositor focus sequence was incomplete")
        return

    var status := "qualified" if _failures.is_empty() else "failed"
    _finish(status, 0 if status == "qualified" else 1, launch, scale_factor, status == "qualified", "" if status == "qualified" else "in-engine assertion failed")


func _wait_for_initial_focus() -> bool:
    for _frame in 600:
        if _pointer_inside and DisplayServer.window_is_focused(DisplayServer.MAIN_WINDOW_ID):
            return true
        if FileAccess.file_exists(_external_unavailable_path):
            return false
        await process_frame
    return false


func _wait_for_focus_step(step: String) -> void:
    for _frame in 600:
        _try_record_panel_focus()
        if _focus_steps.has(step):
            return
        if FileAccess.file_exists(_external_unavailable_path):
            return
        await process_frame
    if not _focus_steps.has(step):
        _failures.append("timed out waiting for observed %s" % step)


func _try_record_panel_focus() -> void:
    if not _awaiting_panel_focus or not _panel_focus_out_observed or not FileAccess.file_exists(_browser_click_sent_path):
        return
    _focus_steps = observed_focus_steps(_focus_steps, "focus_out", _pointer_inside, false, true)
    if _focus_steps == ["capture", "release", "panel_focus"]:
        _write_stage("panel_focus_observed")


func _write_stage(stage: String, extra: Dictionary = {}) -> void:
    _stage_history = append_stage(_stage_history, stage)
    var file := FileAccess.open(_stage_path, FileAccess.WRITE)
    if file == null:
        return
    var evidence := {"stage": stage, "stages": _stage_history, "time_ms": Time.get_ticks_msec()}
    for key in extra:
        evidence[key] = extra[key]
    file.store_string(JSON.stringify(evidence))
    file.close()


func _finish(status: String, exit_code: int, launch: Dictionary, scale_factor: float, input_automation_available := false, qualification_reason := "") -> void:
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    var report := FileAccess.open("%s/report.json" % _out_dir, FileAccess.WRITE)
    if report == null:
        _failures.append("cannot write GSP headed report")
    else:
        report.store_string(JSON.stringify({
            "status": status,
            "passed": status == "qualified" and _failures.is_empty(),
            "exit_code": exit_code,
            "failures": _failures,
            "display_driver": DisplayServer.get_name(),
            "scale_factor": scale_factor,
            "hidpi_qualifying": status == "qualified" and scale_factor >= 2.0,
            "input_automation_available": input_automation_available,
            "input_automation": "verified" if input_automation_available else "unavailable",
            "qualification_reason": qualification_reason,
            "window_mode": DisplayServer.window_get_mode(),
            "borderless": DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS),
            "panel_url": launch.get("panel_url", ""),
            "shell_open_accepted": launch.get("opened", false),
            "focus_steps": _focus_steps,
            "external_focus_required": true,
        }))
        report.close()
    var terminal := terminal_outcome(status)
    if bool(terminal.get("emit_failures", false)):
        for failure in _failures:
            push_error(failure)
    print("GSP headed acceptance: %s" % terminal.get("message", "FAIL"))
    if is_instance_valid(_owned_launcher):
        _owned_launcher.free()
        _owned_launcher = null
    quit(int(terminal.get("exit_code", exit_code)))


func _parse_args() -> void:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--out-dir":
            _out_dir = args[index + 1].trim_suffix("/")


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)
