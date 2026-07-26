extends SceneTree

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")
const GspHeadedAcceptance = preload("res://tests/headed/gsp_headed_acceptance.gd")


func _init() -> void:
	var failures: Array[String] = []
	var disabled := GspLauncher.parse_user_args([])
	if bool(disabled.get("enabled", true)) or bool(disabled.get("open", true)):
		failures.append("GSP is enabled or opened without an explicit user argument")

	var enabled := GspLauncher.parse_user_args(["--aerosim-gsp"])
	if not bool(enabled.get("enabled", false)) or not bool(enabled.get("open", false)):
		failures.append("--aerosim-gsp must enable and open the panel")

	var no_open := GspLauncher.parse_user_args(["--aerosim-gsp", "--aerosim-gsp-no-open"])
	if not bool(no_open.get("enabled", false)) or bool(no_open.get("open", true)):
		failures.append("--aerosim-gsp-no-open must preserve enablement and suppress opening")

	var uri := GspLauncher.file_uri("/tmp/Aero Sim/panel.html")
	if uri != "file:///tmp/Aero%20Sim/panel.html":
		failures.append("file URI is not correctly encoded: %s" % uri)
	if not GspLauncher.is_native_wayland("Wayland") or GspLauncher.is_native_wayland("X11"):
		failures.append("native Wayland detection accepts the wrong display backend")

	var not_qualified := GspHeadedAcceptance.environment_qualification(1.0, false)
	if not_qualified.get("status") != "environment_not_qualified" or int(not_qualified.get("exit_code", 0)) != 2:
		failures.append("1x headed sessions must be environment_not_qualified with exit code 2")
	if float(not_qualified.get("scale_factor", 0.0)) != 1.0 or bool(not_qualified.get("input_automation_available", true)):
		failures.append("environment_not_qualified must preserve scale and unavailable automation evidence")
	var terminal_outcome := GspHeadedAcceptance.terminal_outcome("environment_not_qualified")
	if terminal_outcome.get("message") != "NOT_QUALIFIED" or int(terminal_outcome.get("exit_code", 0)) != 2 or bool(terminal_outcome.get("emit_failures", true)):
		failures.append("environment_not_qualified must print NOT_QUALIFIED without failure errors")
	if not GspHeadedAcceptance.observed_focus_steps([], "focus_out", false, false).is_empty():
		failures.append("focus labels must not be synthesized without the capture/release sequence")
	var panel_focus := GspHeadedAcceptance.observed_focus_steps(["capture", "release"], "focus_out", false, false)
	if panel_focus != ["capture", "release", "panel_focus"]:
		failures.append("panel focus requires an observed focus-out notification")
	var game_focus := GspHeadedAcceptance.observed_focus_steps(panel_focus, "focus_in", true, true)
	if game_focus != ["capture", "release", "panel_focus", "game_focus"]:
		failures.append("game focus requires observed focus-in and pointer/focus state")

	if failures.is_empty():
		print("GSP launch contract: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("GSP launch contract: FAIL")
		quit(1)
