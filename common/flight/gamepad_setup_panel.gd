extends PanelContainer

signal completed(profile)
signal rejected(code: String)

const Calibration = preload("res://common/flight/gamepad_calibration.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")

var step_names := [
	"Detect device", "Live monitor", "Assign axes", "Calibrate endpoints",
	"Detect reverse", "Map Arm/Mode", "Throttle low", "Hover test"
]
var step_index := 0
var calibration := Calibration.GamepadCalibration.new()
var status_label := Label.new()

func _ready() -> void:
	name = "GamepadSetup"
	add_child(status_label)
	_refresh_status()

func submit_axis(role: String, axis: int, range_samples: PackedFloat32Array, stationary_samples: PackedFloat32Array, direction: float) -> bool:
	if not calibration.assign_axis(role, axis) or not calibration.record_axis_range(role, range_samples) or not calibration.record_stationary_samples(role, stationary_samples) or not calibration.set_axis_direction(role, direction):
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	step_index = mini(step_index + 1, step_names.size() - 1)
	_refresh_status()
	return true

func submit_buttons(arm_button: int, mode_button: int, arm_press_ms: int, mode_press_ms: int) -> bool:
	if not calibration.assign_button("arm", arm_button) or not calibration.assign_button("mode", mode_button) or not calibration.record_button_press("arm", arm_press_ms) or not calibration.record_button_press("mode", mode_press_ms):
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	step_index = 6
	_refresh_status()
	return true

func submit_throttle_and_finish(throttle: float) -> bool:
	if not calibration.throttle_is_low(throttle):
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	var profile := calibration.finish()
	if profile == null:
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	step_index = 7
	completed.emit(profile)
	_refresh_status()
	return true

func _refresh_status() -> void:
	status_label.text = "%d/8 %s%s" % [step_index + 1, step_names[step_index], "" if calibration.last_rejection.is_empty() else ": " + calibration.last_rejection]
