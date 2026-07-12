extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")

var _failures: Array[String] = []
var _out_dir := "build/headed"

func _initialize() -> void:
	_run()

func _run() -> void:
	_parse_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://%s" % _out_dir))
	var runtime := SmokeScene.instantiate()
	root.add_child(runtime)
	await _settle(30)

	await _snapshot("00_cold_start")
	_expect(runtime.native != null, "native runtime is registered")
	_expect(root.get_camera_3d() != null, "cold start has an active Camera3D")
	_expect(runtime.screen == "main_menu", "cold start opens the main menu")
	var known_device_id := await _inject_known_gamepad()
	_expect(known_device_id >= 0, "virtual SDL gamepad registers as a known controller")
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

	var unknown_device_id := known_device_id + 1
	Input.joy_connection_changed.emit(known_device_id, false)
	Input.joy_connection_changed.emit(unknown_device_id, true)
	await _settle(10)
	_expect(not Input.is_joy_known(unknown_device_id) and runtime._first_connected_device() == unknown_device_id, "replacement device is connected and lacks an SDL mapping")
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

	await _snapshot("06_exit")
	_write_report()
	if not _failures.is_empty():
		quit(1)
		return
	_tap(KEY_ESCAPE)

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--out-dir":
			_out_dir = args[index + 1].trim_suffix("/")

func _settle(frames: int) -> void:
	for _frame in frames:
		await process_frame

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

func _write_report() -> void:
	var report := FileAccess.open("%s/report.json" % _out_dir, FileAccess.WRITE)
	if report == null:
		push_error("Cannot write headed acceptance report")
		return
	report.store_string(JSON.stringify({"failures": _failures, "passed": _failures.is_empty()}))
	report.close()
