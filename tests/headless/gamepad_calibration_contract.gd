extends SceneTree

const Calibration = preload("res://common/flight/gamepad_calibration.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")

const STATIONARY_SAMPLE_HZ := 100

func _initialize() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	for entry in [["roll", 0], ["pitch", 1], ["yaw", 2], ["throttle", 3]]:
		assert(calibration.assign_axis(entry[0], entry[1]))
		assert(calibration.record_axis_range(entry[0], PackedFloat32Array([-1.0, 1.0])))
		assert(calibration.record_stationary_samples(entry[0], _stationary_samples(0.0, STATIONARY_SAMPLE_HZ), STATIONARY_SAMPLE_HZ))
		assert(calibration.set_axis_direction(entry[0], -1.0 if entry[0] == "pitch" else 1.0))
	assert(calibration.assign_button("arm", JOY_BUTTON_A))
	assert(calibration.assign_button("mode", JOY_BUTTON_Y))
	assert(calibration.record_button_press("arm", 1000))
	assert(calibration.throttle_is_low(0.0))
	var profile := calibration.finish()
	assert(profile != null)
	var gamepad := InputProfiles.GamepadProfile.from_calibration(profile)
	assert(gamepad.axis_for_role == {"roll": 0, "pitch": 1, "yaw": 2, "throttle": 3})
	assert(gamepad.axis_ranges == {
		"roll": {"minimum": -1.0, "maximum": 1.0, "center": 0.0},
		"pitch": {"minimum": -1.0, "maximum": 1.0, "center": 0.0},
		"yaw": {"minimum": -1.0, "maximum": 1.0, "center": 0.0},
		"throttle": {"minimum": -1.0, "maximum": 1.0, "center": 0.0},
	})
	profile.axis_ranges["roll"]["minimum"] = -0.5
	assert(gamepad.axis_ranges["roll"]["minimum"] == -1.0)
	assert(gamepad.arm_button == JOY_BUTTON_A)
	assert(gamepad.mode_button == JOY_BUTTON_Y)
	assert(gamepad.sticky_throttle)
	assert(gamepad.profile_schema_version == 1)
	_test_duplicate_axis()
	_test_endpoint_coverage()
	_test_center_offset()
	_test_stationary_noise()
	_test_stationary_sample_duration()
	_test_button_bounce()
	_test_throttle_not_low()
	_test_endpoint_coverage_boundaries()
	_test_center_offset_boundaries()
	_test_stationary_noise_boundaries()
	_test_button_bounce_boundaries()
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
	assert(not calibration.record_stationary_samples("roll", _stationary_samples(0.03, STATIONARY_SAMPLE_HZ), STATIONARY_SAMPLE_HZ))
	assert(calibration.last_rejection == "center_offset")

func _test_stationary_noise() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_axis("roll", 0))
	assert(calibration.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not calibration.record_stationary_samples("roll", _alternating_stationary_samples(0.01), STATIONARY_SAMPLE_HZ))
	assert(calibration.last_rejection == "stationary_noise")

func _test_stationary_sample_duration() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	assert(calibration.assign_axis("roll", 0))
	assert(calibration.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not calibration.record_stationary_samples("roll", _stationary_samples(0.0, STATIONARY_SAMPLE_HZ - 1), STATIONARY_SAMPLE_HZ))
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

func _test_endpoint_coverage_boundaries() -> void:
	var accepted := Calibration.GamepadCalibration.new()
	assert(accepted.assign_axis("roll", 0))
	assert(accepted.record_axis_range("roll", PackedFloat32Array([-0.95, 0.95])))
	var positive_under := Calibration.GamepadCalibration.new()
	assert(positive_under.assign_axis("roll", 0))
	assert(not positive_under.record_axis_range("roll", PackedFloat32Array([-1.0, 0.949])))
	assert(positive_under.last_rejection == "endpoint_coverage")
	var negative_under := Calibration.GamepadCalibration.new()
	assert(negative_under.assign_axis("roll", 0))
	assert(not negative_under.record_axis_range("roll", PackedFloat32Array([-0.949, 1.0])))
	assert(negative_under.last_rejection == "endpoint_coverage")

func _test_center_offset_boundaries() -> void:
	var accepted := Calibration.GamepadCalibration.new()
	assert(accepted.assign_axis("roll", 0))
	assert(accepted.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(accepted.record_stationary_samples("roll", _stationary_samples(0.02, STATIONARY_SAMPLE_HZ), STATIONARY_SAMPLE_HZ))
	var over_limit := Calibration.GamepadCalibration.new()
	assert(over_limit.assign_axis("roll", 0))
	assert(over_limit.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not over_limit.record_stationary_samples("roll", _stationary_samples(0.0201, STATIONARY_SAMPLE_HZ), STATIONARY_SAMPLE_HZ))
	assert(over_limit.last_rejection == "center_offset")

func _test_stationary_noise_boundaries() -> void:
	var accepted := Calibration.GamepadCalibration.new()
	assert(accepted.assign_axis("roll", 0))
	assert(accepted.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(accepted.record_stationary_samples("roll", _alternating_stationary_samples(0.005), STATIONARY_SAMPLE_HZ))
	var over_limit := Calibration.GamepadCalibration.new()
	assert(over_limit.assign_axis("roll", 0))
	assert(over_limit.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not over_limit.record_stationary_samples("roll", _alternating_stationary_samples(0.0051), STATIONARY_SAMPLE_HZ))
	assert(over_limit.last_rejection == "stationary_noise")

func _test_button_bounce_boundaries() -> void:
	var accepted := Calibration.GamepadCalibration.new()
	assert(accepted.assign_button("arm", JOY_BUTTON_A))
	assert(accepted.record_button_press("arm", 1000))
	assert(accepted.record_button_press("arm", 1050))
	var under_limit := Calibration.GamepadCalibration.new()
	assert(under_limit.assign_button("arm", JOY_BUTTON_A))
	assert(under_limit.record_button_press("arm", 1000))
	assert(not under_limit.record_button_press("arm", 1049))
	assert(under_limit.last_rejection == "button_bounce")

func _stationary_samples(value: float, sample_count: int) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	for _sample in range(sample_count):
		samples.append(value)
	return samples

func _alternating_stationary_samples(magnitude: float) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	for sample in range(STATIONARY_SAMPLE_HZ):
		samples.append(magnitude if sample % 2 == 0 else -magnitude)
	return samples
