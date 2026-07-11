extends SceneTree

const Calibration = preload("res://common/flight/gamepad_calibration.gd")

func _initialize() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	for entry in [["roll", 0], ["pitch", 1], ["yaw", 2], ["throttle", 3]]:
		assert(calibration.assign_axis(entry[0], entry[1]))
		assert(calibration.record_axis_range(entry[0], PackedFloat32Array([-1.0, 1.0])))
		assert(calibration.record_stationary_samples(entry[0], PackedFloat32Array([0.0, 0.0, 0.0, 0.0])))
		assert(calibration.set_axis_direction(entry[0], -1.0 if entry[0] == "pitch" else 1.0))
	assert(calibration.assign_button("arm", JOY_BUTTON_A))
	assert(calibration.assign_button("mode", JOY_BUTTON_Y))
	assert(calibration.record_button_press("arm", 1000))
	assert(calibration.throttle_is_low(0.0))
	assert(calibration.finish() != null)
	_test_duplicate_axis()
	_test_endpoint_coverage()
	_test_center_offset()
	_test_stationary_noise()
	_test_button_bounce()
	_test_throttle_not_low()
	quit(0)

func _test_duplicate_axis() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_axis("roll", 0))
	assert(not calibration.assign_axis("pitch", 0))
	assert(calibration.last_rejection == "duplicate_axis")

func _test_endpoint_coverage() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_axis("roll", 0))
	assert(not calibration.record_axis_range("roll", PackedFloat32Array([-0.8, 0.8])))
	assert(calibration.last_rejection == "endpoint_coverage")

func _test_center_offset() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_axis("roll", 0))
	assert(calibration.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not calibration.record_stationary_samples("roll", PackedFloat32Array([0.03, 0.03, 0.03, 0.03])))
	assert(calibration.last_rejection == "center_offset")

func _test_stationary_noise() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_axis("roll", 0))
	assert(calibration.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not calibration.record_stationary_samples("roll", PackedFloat32Array([-0.01, 0.01, -0.01, 0.01])))
	assert(calibration.last_rejection == "stationary_noise")

func _test_button_bounce() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_button("arm", JOY_BUTTON_A))
	assert(calibration.record_button_press("arm", 1000))
	assert(not calibration.record_button_press("arm", 1020))
	assert(calibration.last_rejection == "button_bounce")

func _test_throttle_not_low() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(not calibration.throttle_is_low(0.3))
	assert(calibration.last_rejection == "throttle_not_low")
