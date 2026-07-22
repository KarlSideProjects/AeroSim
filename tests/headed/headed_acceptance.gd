extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")

class MutableGamepadDeviceState:
	extends GamepadDeviceState.DeviceState

	var snapshot: Array[int] = []
	var known_device_ids: Dictionary = {}

	func replace_snapshot(device_ids: Array[int], known_ids: Array[int]) -> void:
		snapshot = device_ids.duplicate()
		known_device_ids.clear()
		for device_id in known_ids:
			known_device_ids[device_id] = true

	func connected_joypads() -> Array[int]:
		return snapshot.duplicate()

	func is_joy_known(device_id: int) -> bool:
		return bool(known_device_ids.get(device_id, false))

	func joy_name(device_id: int) -> String:
		return "Xbox Test Controller %d" % device_id


class HeadedLicenseProvider:
	extends Node

	func get_snapshot() -> Dictionary:
		return {"ok": true, "status": "online_valid", "last_online_result": "headed_acceptance"}


var _failures: Array[String] = []
var _out_dir := "build/headed"
var _channel_monitor_evidence: Dictionary = {}
var _layout_audit_evidence: Dictionary = {}
var _screenshot_comparison: Dictionary = {}
var _ui_animation_count := 0
var _locale_switch_evidence: Array[Dictionary] = []

func _initialize() -> void:
	_run()

func _run() -> void:
	_parse_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://%s" % _out_dir))
	var runtime := SmokeScene.instantiate()
	var device_state := MutableGamepadDeviceState.new()
	runtime.gamepad_device_state = device_state
	root.add_child(runtime)
	await _settle(30)
	_ui_animation_count = root.find_children("*", "AnimationPlayer", true, false).size()
	_expect(_ui_animation_count == 0, "production UI has no animation players requiring G4B.9 offset-transform review")
	_install_deterministic_valid_license(runtime)

	await _snapshot("00_cold_start")
	_audit_overlay_geometry(runtime, "main_menu")
	_expect(runtime.native != null, "native runtime is registered")
	_expect(root.get_camera_3d() != null, "cold start has an active Camera3D")
	_expect(runtime.screen == "main_menu", "cold start opens the main menu")
	var entries: Array[String] = []
	var entry_rows: Node = runtime.get_node_or_null("MainMenu/Entries")
	if entry_rows != null:
		for entry in entry_rows.get_children():
			entries.append(entry.text)
	_expect(entries == ["Quick Fly", "Lab Mode", "Controller", "Drone", "Map", "Settings", "Quit"], "main menu exposes the exact seven CAP-006 entries in order")
	var drone_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Drone")
	var map_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Map")
	_expect(drone_entry != null and map_entry != null, "main menu exposes Drone and Map setup paths")
	if drone_entry != null:
		_click(drone_entry)
	await _settle(2)
	var flight_setup: Control = runtime.flight_setup_panel
	_expect(runtime.screen == "flight_setup" and flight_setup != null and flight_setup.is_visible_in_tree() and runtime.flight_setup_focus == "drone", "Drone opens shared Flight Setup with Drone focused")
	runtime.show_main_menu()
	await _settle(2)
	if map_entry != null:
		_click(map_entry)
	await _settle(2)
	_expect(runtime.screen == "flight_setup" and runtime.flight_setup_panel == flight_setup and runtime.flight_setup_focus == "map", "Map reuses shared Flight Setup with Map focused")
	runtime.show_main_menu()
	await _settle(2)
	var native_before_lab: Object = runtime.native
	var lab_entry: Button = runtime.get_node_or_null("MainMenu/Entries/LabMode")
	_expect(lab_entry != null, "main menu exposes Lab Mode")
	if lab_entry != null:
		_click(lab_entry)
	await _settle(2)
	_audit_overlay_geometry(runtime, "lab_mode")
	var dashboard: CanvasLayer = runtime.status_diagram
	_expect(runtime.screen == "lab_mode" and runtime.native == native_before_lab, "Lab Mode keeps the same native runtime")
	_expect(dashboard != null and dashboard.call("get_layout_mode") == "full" and bool(dashboard.call("get_render_evidence").get("visible", false)), "Lab Mode shows the full Operations Dashboard")
	var lab_back: Button = runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel/StatusRows/LabBack")
	_expect(lab_back != null and lab_back.is_visible_in_tree(), "Lab Mode exposes a visible Back control")
	if lab_back != null:
		_click(lab_back)
	await _settle(2)
	_expect(runtime.screen == "main_menu" and dashboard != null and dashboard.call("get_layout_mode") == "compact", "Lab Back returns to compact main menu")
	if lab_entry != null:
		_click(lab_entry)
	await _settle(2)
	_expect(runtime.screen == "lab_mode" and dashboard != null and dashboard.call("get_layout_mode") == "full", "Lab Mode reopens for Escape coverage")
	_tap(KEY_ESCAPE)
	await _settle(2)
	_expect(runtime.screen == "main_menu" and dashboard != null and dashboard.call("get_layout_mode") == "compact", "Escape also returns Lab Mode to compact main menu")
	runtime.quit_on_exit = false
	runtime.exit_requested = false
	var quit_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Quit")
	_expect(quit_entry != null, "main menu exposes Quit")
	if quit_entry != null:
		_click(quit_entry)
	await _settle(2)
	_expect(runtime.exit_requested and runtime.screen == "main_menu", "Quit uses cleanup-safe request_exit")
	runtime.exit_requested = false
	await _navigate_graphics_with_ui_actions(runtime, -1)
	await _navigate_graphics_with_ui_actions(runtime, 7)
	_expect(dashboard != null, "cold start attaches the Operations Dashboard")
	if dashboard != null:
		var dashboard_panel := dashboard.get_node_or_null("DashboardMargin/DashboardPanel") as PanelContainer
		_expect(dashboard_panel != null and dashboard_panel.is_visible_in_tree(), "Operations Dashboard renders its panel")
		var render_evidence: Dictionary = dashboard.call("get_render_evidence")
		_expect(bool(render_evidence.get("visible", false)) and render_evidence.get("layout_mode", "") == "compact", "compact dashboard render evidence is observable")
		_expect(bool(render_evidence.get("selector_visible", false)), "Operations Dashboard renders named vehicle selection")
		runtime.set_dashboard_layout_mode("full")
		_expect(dashboard.call("get_layout_mode") == "full", "Operations Dashboard supports full Lab Mode layout")
		runtime.set_dashboard_layout_mode("compact")
	var known_device_id := await _inject_known_gamepad()
	_expect(known_device_id >= 0, "virtual SDL gamepad registers as a known controller")
	device_state.replace_snapshot([known_device_id], [known_device_id])
	Input.joy_connection_changed.emit(known_device_id, true)
	await _settle(2)
	var menu_controller_button: Button = runtime.get_node_or_null("MainMenu/Entries/Controller")
	_expect(menu_controller_button != null, "main menu exposes Controller")
	if menu_controller_button != null:
		_click(menu_controller_button)
	await _settle(2)
	_expect(runtime.screen == "controller_confirmation", "top-level Controller opens confirmation")
	var menu_controller_confirmation: Button = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile")
	_expect(menu_controller_confirmation != null, "top-level Controller exposes confirmation")
	if menu_controller_confirmation != null:
		_click(menu_controller_confirmation)
	await _settle(2)
	_expect(runtime.screen == "main_menu", "top-level Controller confirmation returns to main menu")
	var settings_button: Button = runtime.get_node_or_null("MainMenu/Entries/Settings")
	_expect(settings_button != null, "main menu exposes Settings")
	if settings_button != null:
		_click(settings_button)
	await _settle(2)
	_expect(runtime.screen == "settings", "Settings entry opens Settings")
	var graphics_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Graphics")
	_expect(graphics_button != null, "Settings exposes Graphics")
	if graphics_button != null:
		_click(graphics_button)
	await _settle(2)
	_expect(runtime.screen == "graphics", "Graphics entry opens Graphics")
	var scale_slider: HSlider = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale")
	var apply_button: Button = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/Apply")
	_expect(scale_slider != null and apply_button != null, "Graphics exposes scale and Apply")
	_expect(runtime.get_viewport().gui_get_focus_owner() == scale_slider, "Graphics opens with RenderScale focused")
	var back_button: Button = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/Back")
	if scale_slider != null and apply_button != null:
		scale_slider.value = 0.75
		await _settle(1)
		_expect(absf(runtime.get_viewport().scaling_3d_scale - 0.75) <= 0.000001, "Graphics slider previews the viewport scale")
		apply_button.pressed.emit()
		await _settle(2)
		_expect_persisted_render_scale(runtime, 0.75, "Graphics Apply persists the render scale")
		scale_slider.value = 0.50
		await _settle(1)
	if back_button != null:
		_click(back_button)
	await _settle(2)
	_expect(absf(runtime.get_viewport().scaling_3d_scale - 0.75) <= 0.000001, "Graphics Back restores the committed scale")
	_expect(runtime.get_viewport().gui_get_focus_owner() == graphics_button, "Graphics Back returns focus to the Settings Graphics entry")
	var rates_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Rates")
	_expect(rates_button != null, "Settings exposes Rates")
	if rates_button != null:
		_click(rates_button)
	await _settle(2)
	_expect(runtime.screen == "rates", "Rates entry opens Rates")
	_expect(runtime.rates_panel != null and runtime.rates_panel.is_visible_in_tree(), "Rates panel is visible")
	_expect(runtime.rates_json_editor != null and runtime.rates_json_editor.text.contains("rc_rate"), "Rates panel exposes JSON editor")
	var export_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/ExportJson")
	var import_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/ImportJson")
	var reset_rates_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/ResetDefaults")
	_expect(export_button != null and import_button != null and reset_rates_button != null, "Rates panel exposes JSON export, import, and reset")
	if runtime.rates_json_editor != null:
		runtime.rates_json_editor.text = JSON.stringify({
			"schema_version": 1,
			"rc_rate": 1.15,
			"super_rate": 0.72,
			"expo": 0.25,
		})
	await _settle(1)
	_expect(runtime.rates_diff_label.text.contains("CURRENT vs BETAFLIGHT IMPORTED"), "Rates panel shows current-vs-Betaflight diff")
	if import_button != null:
		var rates_scroll: ScrollContainer = runtime.get_node("MainMenu/RatesPanel/Scroll")
		rates_scroll.scroll_vertical = rates_scroll.get_v_scroll_bar().max_value
		await _settle(1)
		import_button.pressed.emit()
	await _settle(2)
	_expect(absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - 1.15) <= 0.000001, "Rates JSON import applies RC Rate")
	_expect(absf(float(runtime.rates_profile.get("expo", 0.0)) - 0.25) <= 0.000001, "Rates JSON import applies Expo")
	var persisted_rates: Dictionary = runtime.settings_store.load_document()
	var persisted_rate_values = persisted_rates.document.get("rates") if persisted_rates.ok else null
	_expect(persisted_rates.ok and typeof(persisted_rate_values) == TYPE_DICTIONARY and absf(float(persisted_rate_values.get("rc_rate", 0.0)) - 1.15) <= 0.000001, "Rates JSON import persists through SettingsStore")
	if export_button != null:
		export_button.pressed.emit()
	_expect(runtime.rates_json_editor.text.contains("1.15"), "Rates panel exports the current JSON")
	var retained_rc_rate := float(runtime.rates_profile.get("rc_rate", 0.0))
	if runtime.rates_json_editor != null:
		runtime.rates_json_editor.text = "{invalid-json"
	if import_button != null:
		import_button.pressed.emit()
	_expect(runtime.rates_status_label.text.contains("Import rejected") and absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - retained_rc_rate) <= 0.000001, "Invalid rates import is rejected without applying")
	if reset_rates_button != null:
		reset_rates_button.pressed.emit()
	_expect(absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - 1.0) <= 0.000001, "Rates reset restores defaults")
	var rates_back_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/Back")
	if rates_back_button != null:
		runtime.show_settings()
	await _settle(2)
	_expect(runtime.screen == "settings", "Rates panel returns to Settings")
	var settings_controller_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Controller")
	_expect(settings_controller_button != null, "Settings exposes Controller")
	if settings_controller_button != null:
		_click(settings_controller_button)
	await _settle(2)
	_expect(runtime.screen == "controller_settings", "Settings Controller entry opens Controller settings")
	var controller_settings: Control = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel")
	var device_label: Label = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/CurrentDevice")
	var reset_button: Button = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/ResetXboxDefault")
	_expect(controller_settings != null and controller_settings.is_visible_in_tree(), "Controller settings panel is visible")
	_expect(device_label != null and device_label.text.contains(str(known_device_id)), "Controller settings shows the current device")
	_expect(reset_button != null and reset_button.text == "RESET TO XBOX DEFAULT", "Controller settings exposes Xbox reset")
	if reset_button != null:
		_click(reset_button)
	await _settle(2)
	_expect(runtime.screen == "controller_confirmation", "Xbox reset requires confirmation before changing the session profile")
	var reset_confirmation: Button = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile")
	_expect(reset_confirmation != null, "Xbox reset exposes the confirmation action")
	if reset_confirmation != null:
		_click(reset_confirmation)
	await _settle(2)
	_expect(runtime.screen == "controller_settings", "Xbox reset confirmation returns to Controller settings")
	runtime.persisted_gamepad_profile = null
	runtime.session_gamepad_profile = null
	runtime.session_gamepad_device_id = -1
	runtime.show_main_menu()
	var quick_fly_entry: Button = runtime.get_node_or_null("MainMenu/Entries/QuickFly")
	if quick_fly_entry != null:
		_click(quick_fly_entry)
	await _settle(10)
	await _snapshot("01_controller_confirmation")
	_expect(runtime.screen == "controller_confirmation", "known unconfirmed gamepad enters visible Xbox profile confirmation")
	_expect(runtime.controller_confirmation_panel != null and runtime.controller_confirmation_panel.is_visible_in_tree(), "Controller confirmation panel is visible")
	var mapping: Label = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/FixedMapping")
	var axes: Label = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/LiveAxes")
	var confirm_button: Button = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile")
	_expect(mapping != null and mapping.text.contains("roll -> Axis 0") and mapping.text.contains("throttle -> Axis 3"), "confirmation shows fixed Xbox mapping")
	for expected_axis in [
		"roll: Raw +0.500 | Normalized +0.457",
		"pitch: Raw -0.500 | Normalized -0.457",
		"yaw: Raw +0.250 | Normalized +0.185",
		"throttle: Raw -0.750 | Normalized -0.728"
	]:
		_expect(axes != null and axes.text.contains(expected_axis), "confirmation shows live axis value %s" % expected_axis)
	for update in [
		{"axis": JOY_AXIS_LEFT_X, "value": -0.5, "expected": "roll: Raw -0.500 | Normalized -0.457"},
		{"axis": JOY_AXIS_LEFT_Y, "value": 0.5, "expected": "pitch: Raw +0.500 | Normalized +0.457"},
		{"axis": JOY_AXIS_RIGHT_X, "value": -0.25, "expected": "yaw: Raw -0.250 | Normalized -0.185"},
		{"axis": JOY_AXIS_RIGHT_Y, "value": 0.75, "expected": "throttle: Raw +0.750 | Normalized +0.728"}
	]:
		_inject_joy_axis(known_device_id, update.axis, update.value)
		await _settle(2)
		_expect(axes != null and axes.text.contains(update.expected), "confirmation updates live axis value %s" % update.expected)
	_expect(confirm_button != null and confirm_button.text == "USE XBOX DEFAULT PROFILE", "confirmation exposes Xbox default profile action")
	if confirm_button != null:
		_click(confirm_button)
	await _settle(10)
	_expect(runtime.screen == "preflight", "confirmation enters low-throttle preflight")
	_expect(runtime.loaded_map_id == "industrial_yard" and runtime.loaded_map != null, "Quick Fly preflight loads Industrial Yard")
	var spawn := runtime.loaded_map.get_node_or_null("SpawnNorth") as Marker3D if runtime.loaded_map != null else null
	_expect(spawn != null and runtime.drone_body.global_position.distance_to(spawn.global_position) <= 1e-6, "Industrial Yard load places the drone at SpawnNorth")
	var airsim_state: Dictionary = runtime._airsim_state("")
	var airsim_kinematics: Dictionary = airsim_state.get("state", {}).get("kinematics_estimated", {})
	var airsim_position: Dictionary = airsim_kinematics.get("position", {})
	_expect(airsim_state.get("ok", false) and absf(float(airsim_position.get("x_val", 1.0))) <= 1e-6 and absf(float(airsim_position.get("y_val", 1.0))) <= 1e-6 and absf(float(airsim_position.get("z_val", 1.0))) <= 1e-6, "AirSim NED origin follows Industrial Yard SpawnNorth")
	_expect(root.get_camera_3d() == runtime.chase_camera and runtime.chase_camera.current, "Industrial Yard preflight keeps ChaseCamera as the active Camera3D")
	_expect(runtime.time_trial != null and runtime.time_trial.checkpoint_positions.size() == 3, "Industrial Yard exposes a three-checkpoint Time Trial")
	var trial_status: Label = runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel/StatusRows/TimeTrialStatus")
	_expect(trial_status != null and trial_status.text.contains("TIME TRIAL") and trial_status.text.contains("NEXT 1/3"), "preflight HUD exposes the next Time Trial checkpoint")
	var finish_position: Vector3 = runtime.loaded_map.get_node("TimeTrial/Finish").global_position
	if runtime.time_trial != null:
		runtime.time_trial.advance(finish_position, 0.25)
	_expect(runtime.screen == "preflight" and not runtime.time_trial.finished, "preflight cannot finish a Time Trial before takeoff")
	runtime._airsim_disarm_requested = false
	runtime.native.call("arm_flight_control", 0.0)
	runtime.request_takeoff()
	runtime.set_paused(true)
	await _settle(2)
	var paused_position: Vector3 = runtime.drone_body.global_position
	var paused_time: float = runtime.airsim_session.simulation_time_seconds
	runtime.show_controller_settings()
	await _settle(2)
	var monitor: Label = runtime.controller_settings_monitor_label
	_expect(monitor != null and monitor.is_visible_in_tree(), "paused flight opens the visible Channel Monitor")
	_expect(monitor != null and monitor.text.contains("ARM: RELEASED | flight control: ARMED"), "Channel Monitor starts with physical A released and flight control armed")
	_expect(monitor != null and monitor.text.contains("MODE: RELEASED | flight mode: ANGLE"), "Channel Monitor starts with physical Y released and Angle mode")
	var monitor_before_axes := monitor.text if monitor != null else ""
	_inject_joy_button(known_device_id, JOY_BUTTON_A, true)
	await _settle(2)
	_expect(monitor != null and monitor.text.contains("ARM: PRESSED | flight control: ARMED"), "A button physical state remains distinct from already armed control")
	_inject_joy_button(known_device_id, JOY_BUTTON_Y, true)
	await _settle(2)
	_expect(monitor != null and monitor.text.contains("MODE: PRESSED | flight mode: ALTITUDE_HOLD"), "Y button physical state shows the actual resulting flight mode")
	var monitor_start_count: int = runtime.controller_monitor_refresh_count
	var monitor_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - monitor_start_ms < 1_000:
		_inject_joy_axis(known_device_id, JOY_AXIS_LEFT_X, 0.5)
		_inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, -0.5)
		_inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_X, 0.25)
		_inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, -0.75)
		await process_frame
	var monitor_elapsed_seconds := float(Time.get_ticks_msec() - monitor_start_ms) / 1000.0
	var monitor_refresh_count: int = runtime.controller_monitor_refresh_count - monitor_start_count
	var monitor_rate_hz: float = float(monitor_refresh_count) / monitor_elapsed_seconds
	var position_frozen: bool = runtime.drone_body.global_position.distance_to(paused_position) <= 1e-6
	var simulation_time_frozen: bool = absf(runtime.airsim_session.simulation_time_seconds - paused_time) <= 1e-6
	_expect(monitor_rate_hz >= 30.0, "paused Channel Monitor refreshes at least 30 Hz")
	_expect(position_frozen, "Channel Monitor leaves paused physics position frozen")
	_expect(simulation_time_frozen, "Channel Monitor leaves paused simulation time frozen")
	_expect(monitor != null and monitor.text != monitor_before_axes, "Channel Monitor renders injected axes while paused")
	for expected_axis_row in [
		"roll:     [------------|----] raw +0.500 | normalized +0.457",
		"pitch:    [------------|----] raw -0.500 | normalized +0.457",
		"yaw:      [---------|-------] raw +0.250 | normalized +0.185",
		"throttle: [--|--------------] raw -0.750 | normalized -0.728 | LOW",
	]:
		_expect(monitor != null and monitor.text.contains(expected_axis_row), "Channel Monitor renders canonical axis row %s" % expected_axis_row)
	await _snapshot("07_channel_monitor_paused")
	_inject_joy_button(known_device_id, JOY_BUTTON_A, false)
	_inject_joy_button(known_device_id, JOY_BUTTON_Y, false)
	await _settle(2)
	_expect(monitor != null and monitor.text.contains("ARM: RELEASED | flight control: ARMED"), "A release keeps flight control armed")
	_expect(monitor != null and monitor.text.contains("MODE: RELEASED | flight mode: ALTITUDE_HOLD"), "Y release keeps the actual flight mode")
	_channel_monitor_evidence = {
		"elapsed_wall_time_seconds": monitor_elapsed_seconds,
		"refresh_count": monitor_refresh_count,
		"refresh_rate_hz": monitor_rate_hz,
		"position_frozen": position_frozen,
		"simulation_time_frozen": simulation_time_frozen,
		"screenshot_path": "%s/07_channel_monitor_paused.png" % _out_dir,
	}
	runtime.screen = "flight"
	runtime._refresh_flight_hud()
	var pause_rates_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Rates")
	_expect(runtime.paused and pause_rates_button != null, "Pause Overlay exposes Rates")
	var acro_key := InputEventKey.new()
	acro_key.keycode = KEY_C
	acro_key.physical_keycode = KEY_C
	acro_key.pressed = true
	runtime._unhandled_input(acro_key)
	_expect(runtime.flight_mode == "ALTITUDE_HOLD", "C cannot switch to ACRO while paused")
	runtime.show_rates("flight")
	await _settle(2)
	_expect(runtime.screen == "rates" and runtime.paused, "Rates opened from Pause Overlay keeps pause state")
	runtime._close_rates_panel()
	_expect(runtime.screen == "flight" and runtime.paused, "Rates returns to paused flight")
	runtime.set_paused(false)
	runtime._unhandled_input(acro_key)
	_expect(runtime.flight_mode == "ACRO", "C switches to ACRO during flight")
	var curve_before: PackedVector2Array = runtime.rates_curve_line.points
	var rc_slider: HSlider = runtime.rates_sliders["rc_rate"]
	rc_slider.value = 1.25
	await _settle(2)
	_expect(absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - 1.25) <= 0.000001, "Rates slider updates the live ACRO profile")
	var curve_after: PackedVector2Array = runtime.rates_curve_line.points
	_expect(curve_before.size() == curve_after.size() and curve_before.size() > 0 and absf(curve_before[curve_before.size() - 1].y - curve_after[curve_after.size() - 1].y) > 0.000001, "Rates slider updates the native curve preview")
	_complete_time_trial(runtime)
	await _settle(2)
	_expect(runtime.screen == "finish" and runtime.paused, "reaching Finish stops flight and opens the Time Trial result state")
	await _snapshot("06_finish")
	var finish_panel: Control = runtime.get_node_or_null("FlightHud/FinishPanel")
	var finish_summary: Label = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/Summary")
	_expect(finish_panel != null and finish_panel.is_visible_in_tree() and finish_summary != null and finish_summary.text.contains("Time"), "finish panel shows the completed trial time")
	_tap(KEY_P)
	await _settle(2)
	_expect(runtime.screen == "finish" and runtime.paused, "P cannot resume a finished Time Trial")
	var finish_retry: Button = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/Retry")
	_expect(finish_retry != null and finish_retry.text == "RETRY", "finish panel exposes Retry")
	if finish_retry != null:
		_click(finish_retry)
	await _settle(4)
	_expect(runtime.screen == "flight" and not runtime.paused and runtime.time_trial.active and runtime.time_trial.next_checkpoint_index == 0, "Retry respawns at the start and restarts the trial")
	_tap(KEY_P)
	await _settle(2)
	var pause_panel: Control = runtime.get_node_or_null("FlightHud/PausePanel")
	_expect(runtime.paused and pause_panel != null and pause_panel.is_visible_in_tree(), "P opens the pause overlay")
	var paused_trial_time: float = runtime.time_trial.elapsed_seconds
	await _settle(8)
	_expect(absf(runtime.time_trial.elapsed_seconds - paused_trial_time) <= 1e-6, "pause freezes the Time Trial simulation clock")
	var resume_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Resume")
	if resume_button != null:
		_click(resume_button)
	await _settle(2)
	_expect(not runtime.paused, "pause overlay resumes the same flight")
	_tap(KEY_P)
	await _settle(2)
	var change_map_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/ChangeMap")
	if change_map_button != null:
		_click(change_map_button)
	await _settle(4)
	_expect(runtime.screen == "preflight" and runtime.loaded_map_id == "industrial_yard" and not runtime.paused, "Change Map returns to the sole Industrial Yard preflight")
	runtime._airsim_disarm_requested = false
	runtime.native.call("arm_flight_control", 0.0)
	runtime.request_takeoff()
	_complete_time_trial(runtime)
	await _settle(2)
	var finish_change_map: Button = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/ChangeMap")
	_expect(finish_change_map != null and finish_change_map.is_visible_in_tree(), "finish panel exposes Change Map")
	if finish_change_map != null:
		_click(finish_change_map)
	await _settle(4)
	_expect(runtime.screen == "preflight" and runtime.loaded_map_id == "industrial_yard", "finish Change Map returns to preflight")
	runtime._airsim_disarm_requested = false
	runtime.native.call("arm_flight_control", 0.0)
	runtime.request_takeoff()
	_complete_time_trial(runtime)
	await _settle(2)
	var finish_exit: Button = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/Exit")
	_expect(finish_exit != null and finish_exit.is_visible_in_tree(), "finish panel exposes Exit")
	runtime.quit_on_exit = false
	if finish_exit != null:
		_click(finish_exit)
	await _settle(4)
	_expect(runtime.screen == "main_menu" and runtime.loaded_map == null, "finish Exit unloads the map and returns to the main menu")
	_tap(KEY_P)
	await _settle(2)
	_expect(runtime.screen == "main_menu", "P cannot resume after Exit")
	runtime.enter_preflight()
	await _settle(4)
	var industrial_yard_frame := await _snapshot("01_industrial_yard_preflight")
	_expect(_max_color_ratio(industrial_yard_frame) < 0.99, "Industrial Yard preflight capture is not monochrome")
	var camera_rpc: Array = runtime.airsim_rpc_server.dispatch([0, 142, "simGetImages", [[
		{"camera_name": "0", "image_type": 0, "pixels_as_float": false, "compress": true},
		{"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false},
		{"camera_name": "0", "image_type": 5, "pixels_as_float": false, "compress": false},
	], "", false]])
	_expect(camera_rpc[2] == null and camera_rpc[3].size() == 3, "simGetImages returns all requested Industrial Yard camera responses in order")
	if camera_rpc[2] == null and camera_rpc[3].size() == 3:
		var scene_response: Dictionary = camera_rpc[3][0]
		var depth_response: Dictionary = camera_rpc[3][1]
		var segmentation_response: Dictionary = camera_rpc[3][2]
		_expect(scene_response.image_type == 0 and scene_response.width == 256 and scene_response.height == 144 and scene_response.image_data_uint8.size() > 8, "Scene response has AirSim dimensions and PNG bytes")
		var scene_image := Image.new()
		var scene_decode := scene_image.load_png_from_buffer(scene_response.image_data_uint8)
		_expect(scene_decode == OK and not scene_image.is_empty() and _max_color_ratio(scene_image) < 0.99, "Scene PNG decodes to an observable rendered view")
		_expect(depth_response.image_type == 1 and depth_response.pixels_as_float and depth_response.image_data_float.size() == 256 * 144, "DepthPlanar response has one float per pixel")
		_expect(segmentation_response.image_type == 5 and segmentation_response.image_data_uint8.size() == 256 * 144 * 3, "Segmentation raw response has RGB bytes")
		var segmentation_ids := {}
		for offset in range(0, segmentation_response.image_data_uint8.size(), 3):
			var segmentation_id := int(segmentation_response.image_data_uint8[offset]) | (int(segmentation_response.image_data_uint8[offset + 1]) << 8) | (int(segmentation_response.image_data_uint8[offset + 2]) << 16)
			if segmentation_id > 0:
				segmentation_ids[segmentation_id] = true
		_expect(segmentation_ids.has(1), "Segmentation raw response includes the catalog-backed Ground ID")
		_expect(scene_response.time_stamp == depth_response.time_stamp and depth_response.time_stamp == segmentation_response.time_stamp, "multi-request camera responses share one simulation timestamp")
		runtime.airsim_rpc_server.dispatch([0, 144, "simPause", [true]])
		var paused_camera_rpc: Array = runtime.airsim_rpc_server.dispatch([0, 143, "simGetImages", [[{"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false}], "", false]])
		var paused_camera_rpc_again: Array = runtime.airsim_rpc_server.dispatch([0, 145, "simGetImages", [[{"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false}], "", false]])
		_expect(paused_camera_rpc[3][0].time_stamp == depth_response.time_stamp and paused_camera_rpc_again[3][0].time_stamp == paused_camera_rpc[3][0].time_stamp, "paused camera reads keep the simulation timestamp frozen")
		_expect(paused_camera_rpc_again[3][0].image_data_float == paused_camera_rpc[3][0].image_data_float, "paused camera reads repeat the same depth frame")
		runtime.airsim_rpc_server.dispatch([0, 146, "simPause", [false]])
	_expect(not runtime.load_map("missing_map") and runtime.last_error_message.contains("missing_map"), "missing map load names the missing map explicitly")
	_expect(runtime.loaded_map_id == "industrial_yard" and runtime.loaded_map != null, "missing map load keeps Industrial Yard active without a smoke fallback")

	var unknown_device_id := known_device_id + 1
	device_state.replace_snapshot([], [])
	Input.joy_connection_changed.emit(known_device_id, false)
	await _settle(2)
	_expect(runtime.last_profile_status.contains("No controller"), "connection handler refreshes fallback status from the empty adapter snapshot")
	device_state.replace_snapshot([unknown_device_id], [])
	Input.joy_connection_changed.emit(unknown_device_id, true)
	await _settle(10)
	_expect(not device_state.is_joy_known(unknown_device_id) and runtime._first_connected_device() == unknown_device_id, "replacement device is connected and lacks an SDL mapping")
	runtime.quick_fly()
	await _settle(10)
	_expect(runtime.screen == "fallback_prompt", "Quick Fly blocks the replaced unknown controller at KeyboardProfile fallback")
	_expect(runtime.arm_status_label != null and runtime.arm_status_label.text.contains("Unsupported controller"), "unknown controller fallback is explicit")

	await _snapshot("02_keyboard_fallback")
	var fallback_button: Button = runtime.arm_takeoff_button
	_expect(fallback_button != null and fallback_button.text == "USE KEYBOARD FALLBACK", "unknown controller exposes the KeyboardProfile fallback control")
	if fallback_button != null:
		_click(fallback_button)
	await _settle(10)
	_expect(runtime.screen == "preflight", "KeyboardProfile fallback enters low-throttle preflight")

	_tap(KEY_T)
	await _settle(60)
	_audit_overlay_geometry(runtime, "flight")
	await _snapshot("03_takeoff")
	_expect(runtime.takeoff_requested, "T requests takeoff after Quick Fly")

	_tap(KEY_P)
	await _settle(10)
	await _snapshot("04_paused")
	_expect(runtime.paused, "P pauses flight")

	_tap(KEY_P)
	_tap(KEY_R)
	await _settle(10)
	await _snapshot("05_reset")
	_expect(runtime.reset_count >= 1, "R resets flight after resume")
	spawn = runtime.loaded_map.get_node_or_null("SpawnNorth") as Marker3D if runtime.loaded_map != null else null
	_expect(spawn != null and runtime.drone_body.global_position.distance_to(spawn.global_position) <= 1e-6 and runtime.drone_body.linear_velocity.length() <= 1e-6 and runtime.drone_body.angular_velocity.length() <= 1e-6, "reset returns to SpawnNorth with cleared velocities")

	runtime.quit_on_exit = false
	_tap(KEY_ESCAPE)
	await _settle(2)
	await _snapshot("06_exit")
	_expect(runtime.exit_requested and runtime.screen == "main_menu" and runtime.loaded_map == null and runtime.get_node_or_null("LoadedMap") == null, "exit frees the map and returns to the main menu stub")
	await _audit_localization(runtime)
	if not _write_report():
		quit(1)
		return
	if not _failures.is_empty():
		for failure in _failures:
			print("HEADED FAILURE: %s" % failure)
		quit(1)
		return
	quit(0)

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--out-dir":
			_out_dir = args[index + 1].trim_suffix("/")


func _install_deterministic_valid_license(runtime: Node) -> void:
	if runtime.license_provider != null:
		runtime.remove_child(runtime.license_provider)
		runtime.license_provider.queue_free()
	var provider := HeadedLicenseProvider.new()
	runtime.license_provider = provider
	runtime.add_child(provider)
	runtime.show_main_menu()


func _settle(frames: int) -> void:
	for _frame in frames:
		await process_frame

func _complete_time_trial(runtime: Node) -> void:
	if runtime.time_trial == null:
		return
	for checkpoint in runtime.time_trial.checkpoint_positions:
		runtime.time_trial.advance(checkpoint, 1.0 / 240.0)
	var finish_position: Vector3 = runtime.loaded_map.get_node("TimeTrial/Finish").global_position
	runtime.time_trial.advance(finish_position, 1.0 / 240.0)

func _snapshot(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image.save_png("%s/%s.png" % [_out_dir, name]) != OK:
		_failures.append("cannot save screenshot %s" % name)
	_expect(_max_color_ratio(image) < 0.99, "%s is not a monochrome frame" % name)
	return image

func _max_color_ratio(image: Image) -> float:
	image.convert(Image.FORMAT_RGBA8)
	var counts := {}
	var max_count := 0
	var data := image.get_data()
	for offset in range(0, data.size(), 4):
		var color := (int(data[offset]) << 16) | (int(data[offset + 1]) << 8) | int(data[offset + 2])
		counts[color] = int(counts.get(color, 0)) + 1
		max_count = maxi(max_count, counts[color])
	return float(max_count) / float(image.get_width() * image.get_height())

func _tap(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		Input.parse_input_event(event)

func _send_ui_action(action: String, device: int) -> void:
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = action
		event.device = device
		event.pressed = pressed
		event.strength = 1.0
		Input.parse_input_event(event)

func _navigate_graphics_with_ui_actions(runtime: Node, device: int) -> void:
	var reset_result: Dictionary = runtime.settings_store.factory_reset()
	_expect(reset_result.ok, "UI action flow resets SettingsStore")
	runtime.render_scale = 1.0
	runtime.graphics_committed_scale = 1.0
	runtime.get_viewport().scaling_3d_scale = 1.0
	runtime.show_main_menu()
	await _settle(1)
	var quick_fly := runtime.get_node_or_null("MainMenu/Entries/QuickFly") as Button
	_expect(runtime.get_viewport().gui_get_focus_owner() == quick_fly, "UI action flow starts on Quick Fly")
	for _step in range(5):
		_send_ui_action("ui_down", device)
		await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "settings", "UI actions open Settings")
	var graphics_button := runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Graphics") as Button
	_expect(runtime.get_viewport().gui_get_focus_owner() == graphics_button, "Settings hands focus to Graphics")
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "graphics", "UI actions open Graphics")
	var slider := runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale") as HSlider
	_expect(runtime.get_viewport().gui_get_focus_owner() == slider, "Graphics UI actions focus RenderScale")
	for _step in range(10):
		_send_ui_action("ui_right", device)
		await _settle(1)
	for _step in range(5):
		_send_ui_action("ui_left", device)
		await _settle(1)
	_expect(absf(runtime.get_viewport().scaling_3d_scale - 0.75) <= 0.000001, "UI actions change Graphics scale")
	_expect((runtime.get_node("MainMenu/GraphicsPanel/Rows/RenderScaleValue") as Label).text == "RENDER SCALE: 75%", "Graphics shows integer percent")
	_send_ui_action("ui_down", device)
	await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect_persisted_render_scale(runtime, 0.75, "UI actions Apply Graphics")
	for _step in range(2):
		_send_ui_action("ui_down", device)
		await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "settings", "UI actions return from Graphics")
	_expect(runtime.get_viewport().gui_get_focus_owner() == graphics_button, "UI actions return Settings focus")
	for _step in range(2):
		_send_ui_action("ui_down", device)
		await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "main_menu", "UI actions return to main menu")

func _click(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)

func _audit_localization(runtime: Node) -> void:
	var switch_started_us := Time.get_ticks_usec()
	var switched_to_zh_tw: bool = runtime.set_locale("zh_TW")
	var switch_elapsed_us := Time.get_ticks_usec() - switch_started_us
	_locale_switch_evidence.append({"from": "en", "to": "zh_TW", "elapsed_us": switch_elapsed_us, "threshold_us": 100_000})
	_expect(switched_to_zh_tw, "UI locale switches to Traditional Chinese")
	_expect(switch_elapsed_us <= 100_000, "locale switch does not block input for more than 100 ms")
	if not switched_to_zh_tw:
		var language_load: Dictionary = runtime.settings_store.load_document()
		_failures.append("locale switch diagnostic: %s runtime=%s" % [language_load.get("error", "unknown"), runtime.last_error_message])
	await _settle(2)
	runtime.show_main_menu()
	await _settle(1)
	var quick_fly: Button = runtime.get_node_or_null("MainMenu/Entries/QuickFly")
	_expect(quick_fly != null and quick_fly.text == "快速飛行", "Traditional Chinese localizes the main menu immediately")
	_audit_visible_controls(runtime, "main_menu_zh_tw")
	runtime.show_settings()
	await _settle(1)
	var settings_title: Label = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Title")
	var language_selector: OptionButton = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Language")
	_expect(settings_title != null and settings_title.text == "設定", "Traditional Chinese localizes Settings immediately")
	_expect(language_selector != null and language_selector.get_item_text(1) == "繁體中文", "Language selector localizes its own options")
	var settings_status: Label = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Status")
	_expect(settings_status != null and settings_status.text.contains("不支援"), "Traditional Chinese localizes the visible controller diagnostic")
	_expect(settings_status == null or not settings_status.text.contains("Unsupported controller"), "Traditional Chinese removes the visible English controller diagnostic")
	_audit_visible_controls(runtime, "settings_zh_tw")
	runtime.show_main_menu()
	await _settle(1)
	var drone_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Drone")
	if drone_entry != null:
		_click(drone_entry)
	await _settle(1)
	var flight_mode_label: Label = runtime.get_node_or_null("MainMenu/FlightSetupPanel/Rows/Mode")
	_expect(flight_mode_label != null and flight_mode_label.text == "模式：角度", "Traditional Chinese localizes the dynamic Flight Setup mode")
	runtime.flight_mode = "UNSUPPORTED_RUNTIME_MODE"
	runtime.update_fallback_status()
	_expect(runtime.fallback_status_label != null and runtime.fallback_status_label.text.contains("未知模式"), "Traditional Chinese wraps unknown runtime modes in the catalog")
	_expect(runtime.fallback_status_label == null or not runtime.fallback_status_label.text.contains("UNSUPPORTED_RUNTIME_MODE"), "Traditional Chinese hides unknown runtime mode tokens")
	runtime.flight_mode = "ANGLE"
	runtime.update_fallback_status()
	_audit_visible_controls(runtime, "flight_setup_zh_tw")
	runtime.show_settings()
	await _settle(1)
	runtime.show_controller_settings()
	await _settle(1)
	_audit_visible_controls(runtime, "controller_settings_zh_tw")
	runtime.show_rates()
	await _settle(1)
	_audit_visible_controls(runtime, "rates_zh_tw")
	runtime.show_graphics()
	await _settle(1)
	_audit_visible_controls(runtime, "graphics_zh_tw")
	await _audit_transient_localization(runtime, "zh_tw")
	runtime.show_settings()
	await _settle(1)
	_expect(runtime.load_map("industrial_yard"), "Traditional Chinese can load the Industrial Yard")
	await _settle(2)
	var north_spawn_label: Label3D = runtime.loaded_map.get_node_or_null("SpawnNorth/DirectionLabel") if runtime.loaded_map != null else null
	_expect(north_spawn_label != null and north_spawn_label.text == "北側起飛點", "Industrial Yard Label3D localizes with the active locale")
	runtime.unload_map()
	var zh_tw_image := await _snapshot("08_zh_tw_settings")
	var switch_back_started_us := Time.get_ticks_usec()
	var switched_to_en: bool = runtime.set_locale("en")
	var switch_back_elapsed_us := Time.get_ticks_usec() - switch_back_started_us
	_locale_switch_evidence.append({"from": "zh_TW", "to": "en", "elapsed_us": switch_back_elapsed_us, "threshold_us": 100_000})
	_expect(switched_to_en, "UI locale switches back to English")
	_expect(switch_back_elapsed_us <= 100_000, "English locale switch does not block input for more than 100 ms")
	await _settle(2)
	_expect(settings_title != null and settings_title.text == "SETTINGS", "English locale restores Settings immediately")
	runtime.show_main_menu()
	await _settle(1)
	_audit_visible_controls(runtime, "main_menu_en")
	var english_drone_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Drone")
	if english_drone_entry != null:
		_click(english_drone_entry)
	await _settle(1)
	var english_flight_mode_label: Label = runtime.get_node_or_null("MainMenu/FlightSetupPanel/Rows/Mode")
	_expect(english_flight_mode_label != null and english_flight_mode_label.text == "MODE: ANGLE", "English localizes the dynamic Flight Setup mode")
	_audit_visible_controls(runtime, "flight_setup_en")
	runtime.show_settings()
	await _settle(1)
	_audit_visible_controls(runtime, "settings_en")
	runtime.show_controller_settings()
	await _settle(1)
	_audit_visible_controls(runtime, "controller_settings_en")
	runtime.show_rates()
	await _settle(1)
	_audit_visible_controls(runtime, "rates_en")
	runtime.show_graphics()
	await _settle(1)
	_audit_visible_controls(runtime, "graphics_en")
	await _audit_transient_localization(runtime, "en")
	runtime.show_settings()
	await _settle(1)
	var en_image := await _snapshot("09_en_settings_roundtrip")
	_compare_locale_screenshots(zh_tw_image, en_image)

func _audit_transient_localization(runtime: Node, locale_suffix: String) -> void:
	runtime.screen = "flight"
	runtime.set_paused(true, false)
	runtime.call("_refresh_flight_hud")
	await _settle(1)
	_audit_visible_controls(runtime, "pause_%s" % locale_suffix)

	runtime.call("_on_trial_finished", 12.34)
	await _settle(1)
	_audit_visible_controls(runtime, "finish_%s" % locale_suffix)

	runtime.call("_show_license_blocked", "Quick Fly unavailable: license invalid_token")
	await _settle(1)
	_audit_visible_controls(runtime, "license_%s" % locale_suffix)

	runtime.call("_show_keyboard_fallback", "Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
	await _settle(1)
	_audit_visible_controls(runtime, "fallback_%s" % locale_suffix)

	var connected_devices: Array[int] = [0]
	runtime.gamepad_device_state.call("replace_snapshot", connected_devices, connected_devices)
	runtime.controller_safety_latched = true
	runtime.call("begin_controller_confirmation", 0)
	await _settle(1)
	_expect(runtime.screen == "controller_confirmation", "controller confirmation transient state opens")
	_expect(runtime.controller_safety_panel != null and not runtime.controller_safety_panel.is_visible_in_tree(), "controller safety banner yields to confirmation modal")
	_audit_visible_controls(runtime, "controller_confirmation_%s" % locale_suffix)

	runtime.controller_safety_latched = false
	runtime.last_error_message = "Flight Setup contains an unsupported selection"
	runtime.screen = "error"
	runtime.call("_refresh_flight_hud")
	await _settle(1)
	_audit_visible_controls(runtime, "error_%s" % locale_suffix)

	runtime.set_paused(false, false)
	runtime.last_error_message = ""
	var no_devices: Array[int] = []
	runtime.gamepad_device_state.call("replace_snapshot", no_devices, no_devices)
	runtime.session_gamepad_device_id = -1
	runtime.show_settings()
	await _settle(1)

func _audit_visible_controls(node: Node, screen_name: String) -> void:
	var viewport_rect := root.get_viewport().get_visible_rect()
	var text_controls: Array[Control] = []
	_collect_visible_text_controls(node, text_controls)
	var overlap_count := 0
	var clipping_count := 0
	for control in text_controls:
		var rect := control.get_global_rect()
		_expect(viewport_rect.encloses(rect), "localized control remains inside viewport: %s" % control.get_path())
		_expect(not String(control.text).begins_with("ui."), "localized control does not expose a translation key: %s" % control.get_path())
		var minimum_size := control.get_combined_minimum_size()
		if minimum_size.x > rect.size.x + 1.0 or minimum_size.y > rect.size.y + 1.0:
			clipping_count += 1
			_expect(false, "localized control text exceeds its allocated rect: %s" % control.get_path())
	for first_index in range(text_controls.size()):
		var first := text_controls[first_index]
		for second_index in range(first_index + 1, text_controls.size()):
			var second := text_controls[second_index]
			if first.get_global_rect().intersection(second.get_global_rect()).get_area() > 0.5:
				overlap_count += 1
				_expect(false, "localized text controls overlap: %s and %s" % [first.get_path(), second.get_path()])
	var screens: Dictionary = _layout_audit_evidence.get("screens", {})
	screens[screen_name] = {"text_controls": text_controls.size(), "clipping_count": clipping_count, "overlap_count": overlap_count}
	_layout_audit_evidence["screens"] = screens

func _collect_visible_text_controls(node: Node, controls: Array[Control]) -> void:
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if control.is_visible_in_tree() and (control is Label or control is Button or control is OptionButton or control is LineEdit or control is TextEdit):
				controls.append(control)
		_collect_visible_text_controls(child, controls)

func _audit_overlay_geometry(runtime: Node, screen_name: String) -> void:
	var surfaces: Array[Dictionary] = []
	_add_overlay_surface(surfaces, "main_menu", runtime.get_node_or_null("MainMenu/Entries"))
	_add_overlay_surface(surfaces, "flight_hud", runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel"))
	var dashboard: CanvasLayer = runtime.status_diagram
	if dashboard != null:
		_add_overlay_surface(surfaces, "operations_dashboard", dashboard.get_node_or_null("DashboardMargin/DashboardPanel"))
	var body_drag: Node = runtime.body_drag_debug_panel
	if body_drag != null:
		var body_panel: Control = body_drag.get("_panel")
		if body_panel != null:
			var body_surface: Control = body_panel.get("_scroll") if body_panel.get("_scroll") != null else body_panel.get("container")
			_add_overlay_surface(surfaces, "body_drag", body_surface)

	var viewport_rect := root.get_viewport().get_visible_rect()
	var geometry: Dictionary = {}
	for surface in surfaces:
		var control: Control = surface.control
		var rect := control.get_global_rect()
		_expect(viewport_rect.encloses(rect), "%s overlay remains inside viewport: %s" % [screen_name, surface.name])
		geometry[surface.name] = {
			"left": rect.position.x,
			"top": rect.position.y,
			"right": rect.end.x,
			"bottom": rect.end.y,
			"width": rect.size.x,
			"height": rect.size.y,
		}
	for first_index in range(surfaces.size()):
		var first: Control = surfaces[first_index].control
		for second_index in range(first_index + 1, surfaces.size()):
			var second: Control = surfaces[second_index].control
			var first_rect := first.get_global_rect()
			var second_rect := second.get_global_rect()
			_expect(first_rect.grow(8.0).intersection(second_rect).get_area() <= 0.5,
					"%s overlays keep 8 px spacing: %s and %s" % [screen_name, surfaces[first_index].name, surfaces[second_index].name])
	var overlays: Dictionary = _layout_audit_evidence.get("overlays", {})
	overlays[screen_name] = geometry
	_layout_audit_evidence["overlays"] = overlays

func _add_overlay_surface(surfaces: Array[Dictionary], name: String, node: Node) -> void:
	if node is Control and node.is_visible_in_tree():
		surfaces.append({"name": name, "control": node})

func _compare_locale_screenshots(zh_tw_image: Image, en_image: Image) -> void:
	var same_dimensions := zh_tw_image.get_size() == en_image.get_size()
	_expect(same_dimensions, "locale screenshots keep the same viewport dimensions")
	if not same_dimensions:
		return
	var changed_pixels := 0
	var total_pixels := zh_tw_image.get_width() * zh_tw_image.get_height()
	for y in range(zh_tw_image.get_height()):
		for x in range(zh_tw_image.get_width()):
			var zh_color := zh_tw_image.get_pixel(x, y)
			var en_color := en_image.get_pixel(x, y)
			if absf(zh_color.r - en_color.r) + absf(zh_color.g - en_color.g) + absf(zh_color.b - en_color.b) > 0.03:
				changed_pixels += 1
	var changed_ratio := float(changed_pixels) / float(total_pixels)
	_expect(changed_ratio >= 0.001, "locale screenshot comparison detects the translated UI")
	_screenshot_comparison = {"width": zh_tw_image.get_width(), "height": zh_tw_image.get_height(), "changed_pixels": changed_pixels, "changed_ratio": changed_ratio}


func _inject_known_gamepad() -> int:
	_inject_joy_axis(0, JOY_AXIS_LEFT_X, 0.5)
	_inject_joy_axis(0, JOY_AXIS_LEFT_Y, -0.5)
	_inject_joy_axis(0, JOY_AXIS_RIGHT_X, 0.25)
	_inject_joy_axis(0, JOY_AXIS_RIGHT_Y, -0.75)
	await process_frame
	for device_id in Input.get_connected_joypads():
		if Input.is_joy_known(device_id):
			return device_id
	return -1

func _inject_joy_axis(device_id: int, axis: JoyAxis, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device_id
	event.axis = axis
	event.axis_value = value
	Input.parse_input_event(event)

func _inject_joy_button(device_id: int, button: JoyButton, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device_id
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)

func _expect_persisted_render_scale(runtime: Node, expected_scale: float, message: String) -> void:
	var persisted: Dictionary = runtime.settings_store.load_document()
	var quality: Variant = persisted.document.get("quality") if persisted.ok else null
	var persisted_quality: Dictionary = quality if quality is Dictionary else {}
	_expect(persisted.ok and quality is Dictionary and absf(float(persisted_quality.get("render_scale", 0.0)) - expected_scale) <= 0.000001, message)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _write_report() -> bool:
	var report := FileAccess.open("%s/report.json" % _out_dir, FileAccess.WRITE)
	if report == null:
		push_error("Cannot write headed acceptance report")
		return false
	var version_info := Engine.get_version_info()
	var provenance := {
		"commit_sha": OS.get_environment("AEROSIM_HEADED_COMMIT_SHA"),
		"godot_version": String(version_info.get("string", "")),
		"os": OS.get_name(),
		"display_driver": DisplayServer.get_name(),
		"gpu_adapter": RenderingServer.get_video_adapter_name(),
		"vulkan_icd": OS.get_environment("VK_ICD_FILENAMES"),
	}
	report.store_string(JSON.stringify({"provenance": provenance, "channel_monitor": _channel_monitor_evidence, "layout_audit": _layout_audit_evidence, "screenshot_comparison": _screenshot_comparison, "locale_switches": _locale_switch_evidence, "ui_animation_count": _ui_animation_count, "failures": _failures, "passed": _failures.is_empty()}))
	report.close()
	return true
