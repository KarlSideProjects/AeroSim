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

var _failures: Array[String] = []
var _out_dir := "build/headed"

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

	await _snapshot("00_cold_start")
	_expect(runtime.native != null, "native runtime is registered")
	_expect(root.get_camera_3d() != null, "cold start has an active Camera3D")
	_expect(runtime.screen == "main_menu", "cold start opens the main menu")
	var known_device_id := await _inject_known_gamepad()
	_expect(known_device_id >= 0, "virtual SDL gamepad registers as a known controller")
	device_state.replace_snapshot([known_device_id], [known_device_id])
	Input.joy_connection_changed.emit(known_device_id, true)
	await _settle(2)
	var settings_button: Button = runtime.get_node_or_null("MainMenu/Entries/Settings")
	_expect(settings_button != null, "main menu exposes Settings")
	if settings_button != null:
		_click(settings_button)
	await _settle(2)
	_expect(runtime.screen == "settings", "Settings entry opens Settings")
	var settings_controller_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Controller")
	_expect(settings_controller_button != null, "Settings exposes Controller")
	if settings_controller_button != null:
		_click(settings_controller_button)
	await _settle(2)
	_expect(runtime.screen == "controller_settings", "Settings Controller entry opens Controller settings")
	var controller_settings: Control = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel")
	var device_label: Label = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/CurrentDevice")
	var fixed_mapping_label: Label = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/FixedMapping")
	var deadzone_label: Label = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/Deadzone")
	var button_status_label: Label = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/ButtonStatus")
	var reset_button: Button = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/ResetXboxDefault")
	_expect(controller_settings != null and controller_settings.is_visible_in_tree(), "Controller settings panel is visible")
	_expect(device_label != null and device_label.text.contains(str(known_device_id)), "Controller settings shows the current device")
	_expect(fixed_mapping_label != null and fixed_mapping_label.text.contains("roll -> Axis 0") and fixed_mapping_label.text.contains("throttle -> Axis 3"), "Controller settings shows the fixed Xbox mapping")
	_expect(deadzone_label != null and deadzone_label.text.contains("0.080"), "Controller settings shows the fixed deadzone")
	_expect(button_status_label != null and button_status_label.text.contains("Arm RELEASED") and button_status_label.text.contains("Mode RELEASED"), "Controller settings shows Arm/Mode status")
	_expect(reset_button != null and reset_button.text == "RESET TO XBOX DEFAULT", "Controller settings exposes Xbox reset")
	if reset_button != null:
		_click(reset_button)
	await _settle(2)
	_expect(runtime.screen == "controller_confirmation", "Xbox reset requires confirmation before changing the session profile")
	runtime.quick_fly()
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
	if not _write_report():
		quit(1)
		return
	if not _failures.is_empty():
		quit(1)
		return
	quit(0)

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--out-dir":
			_out_dir = args[index + 1].trim_suffix("/")

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

func _click(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)

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

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _write_report() -> bool:
	var report := FileAccess.open("%s/report.json" % _out_dir, FileAccess.WRITE)
	if report == null:
		push_error("Cannot write headed acceptance report")
		return false
	report.store_string(JSON.stringify({"failures": _failures, "passed": _failures.is_empty()}))
	report.close()
	return true
