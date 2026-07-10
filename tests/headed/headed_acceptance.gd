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

	var quick_fly: Button = runtime.get_node_or_null("MainMenu/Entries/QuickFly")
	_expect(quick_fly != null, "main menu exposes Quick Fly button")
	if quick_fly != null:
		_click(quick_fly)
	await _settle(10)
	await _snapshot("01_quick_fly")
	if runtime.screen == "fallback_prompt":
		var fallback_button: Button = runtime.arm_takeoff_button
		_expect(fallback_button != null and fallback_button.text == "USE KEYBOARD FALLBACK", "Quick Fly exposes the KeyboardProfile fallback control")
		if fallback_button != null:
			_click(fallback_button)
		await _settle(10)
		_expect(runtime.screen == "preflight", "KeyboardProfile fallback enters low-throttle preflight")

	_tap(KEY_T)
	await _settle(60)
	await _snapshot("02_takeoff")
	_expect(runtime.takeoff_requested, "T requests takeoff after Quick Fly")

	_tap(KEY_P)
	await _settle(10)
	await _snapshot("03_paused")
	_expect(runtime.paused, "P pauses flight")

	_tap(KEY_P)
	_tap(KEY_R)
	await _settle(10)
	await _snapshot("04_reset")
	_expect(runtime.reset_count >= 1, "R resets flight after resume")

	await _snapshot("05_exit")
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
