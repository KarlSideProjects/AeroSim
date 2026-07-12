extends PanelContainer

signal completed(profile)
signal rejected(code: String)

const Calibration = preload("res://common/flight/gamepad_calibration.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")
const AXIS_ROLES := ["roll", "pitch", "yaw", "throttle"]

var step_names := [
	"Detect device", "Live monitor", "Assign axes", "Calibrate endpoints",
	"Detect reverse", "Map Arm/Mode", "Throttle low", "Hover test"
]
var step_index := 0
var calibration := Calibration.GamepadCalibration.new()
var status_label := Label.new()
var action_button := Button.new()
var _axis_assignments := {}
var _axis_ranges := {}
var _stationary_samples := {}
var _axis_directions := {}
var _button_mapping := {}
var _button_press_times := {}

func _ready() -> void:
	name = "GamepadSetup"
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	add_child(rows)
	status_label.name = "Status"
	rows.add_child(status_label)
	action_button.name = "Advance"
	action_button.pressed.connect(_advance_current_step)
	rows.add_child(action_button)
	_refresh_status()

func advance_detect_device() -> bool:
	if not _require_step(0):
		return false
	return _accept_step(1)

func advance_live_monitor() -> bool:
	if not _require_step(1):
		return false
	return _accept_step(2)

func submit_axis_assignment(role: String, axis: int) -> bool:
	if not _require_step(2):
		return false
	if not AXIS_ROLES.has(role):
		return _reject("duplicate_axis")
	var assignments := _axis_assignments.duplicate()
	assignments[role] = axis
	var candidate := _build_candidate(assignments, _axis_ranges, _stationary_samples, _axis_directions, _button_mapping, _button_press_times)
	if not candidate.last_rejection.is_empty():
		return _reject(candidate.last_rejection)
	_axis_assignments = assignments
	return _accept_step(3 if _axis_assignments.size() == AXIS_ROLES.size() else 2)

func submit_axis_endpoints(role: String, range_samples: PackedFloat32Array, stationary_samples: PackedFloat32Array) -> bool:
	if not _require_step(3):
		return false
	if not _axis_assignments.has(role):
		return _reject("endpoint_coverage")
	var ranges := _axis_ranges.duplicate()
	var stationary := _stationary_samples.duplicate()
	ranges[role] = range_samples.duplicate()
	stationary[role] = stationary_samples.duplicate()
	var candidate := _build_candidate(_axis_assignments, ranges, stationary, _axis_directions, _button_mapping, _button_press_times)
	if not candidate.last_rejection.is_empty():
		return _reject(candidate.last_rejection)
	_axis_ranges = ranges
	_stationary_samples = stationary
	return _accept_step(4 if _axis_ranges.size() == AXIS_ROLES.size() else 3)

func submit_axis_direction(role: String, direction: float) -> bool:
	if not _require_step(4):
		return false
	if not _axis_ranges.has(role):
		return _reject("endpoint_coverage")
	var directions := _axis_directions.duplicate()
	directions[role] = direction
	var candidate := _build_candidate(_axis_assignments, _axis_ranges, _stationary_samples, directions, _button_mapping, _button_press_times)
	if not candidate.last_rejection.is_empty():
		return _reject(candidate.last_rejection)
	_axis_directions = directions
	if _axis_directions.size() == AXIS_ROLES.size():
		calibration = candidate
		return _accept_step(5)
	return _accept_step(4)

func submit_buttons(arm_button: int, mode_button: int, arm_press_ms: int, mode_press_ms: int) -> bool:
	if not _require_step(5):
		return false
	var buttons := {"arm": arm_button, "mode": mode_button}
	var press_times := {"arm": arm_press_ms, "mode": mode_press_ms}
	var candidate := _build_candidate(_axis_assignments, _axis_ranges, _stationary_samples, _axis_directions, buttons, press_times)
	if not candidate.last_rejection.is_empty():
		return _reject(candidate.last_rejection)
	_button_mapping = buttons
	_button_press_times = press_times
	calibration = candidate
	return _accept_step(6)

func submit_throttle_low(throttle: float) -> bool:
	if not _require_step(6):
		return false
	var candidate := _build_candidate(_axis_assignments, _axis_ranges, _stationary_samples, _axis_directions, _button_mapping, _button_press_times)
	if not candidate.throttle_is_low(throttle):
		return _reject(candidate.last_rejection)
	calibration = candidate
	return _accept_step(7)

func submit_hover_test() -> bool:
	if not _require_step(7):
		return false
	var candidate := _build_candidate(_axis_assignments, _axis_ranges, _stationary_samples, _axis_directions, _button_mapping, _button_press_times)
	var profile := candidate.finish()
	if profile == null:
		return _reject(candidate.last_rejection)
	calibration = candidate
	calibration.last_rejection = ""
	completed.emit(profile)
	_refresh_status()
	return true

func _advance_current_step() -> void:
	if step_index == 0:
		advance_detect_device()
	elif step_index == 1:
		advance_live_monitor()
	elif step_index == 7:
		submit_hover_test()

func _build_candidate(assignments: Dictionary, ranges: Dictionary, stationary: Dictionary, directions: Dictionary, buttons: Dictionary, press_times: Dictionary) -> Calibration.GamepadCalibration:
	var candidate := Calibration.GamepadCalibration.new()
	for role in AXIS_ROLES:
		if assignments.has(role) and not candidate.assign_axis(role, assignments[role]):
			return candidate
		if ranges.has(role):
			if not candidate.record_axis_range(role, ranges[role]) or not candidate.record_stationary_samples(role, stationary[role]):
				return candidate
		if directions.has(role) and not candidate.set_axis_direction(role, directions[role]):
			return candidate
	for role in ["arm", "mode"]:
		if buttons.has(role):
			if not candidate.assign_button(role, buttons[role]) or not candidate.record_button_press(role, press_times[role]):
				return candidate
	return candidate

func _require_step(expected_step: int) -> bool:
	if step_index == expected_step:
		return true
	_reject("out_of_order")
	return false

func _accept_step(next_step: int) -> bool:
	step_index = next_step
	calibration.last_rejection = ""
	_refresh_status()
	return true

func _reject(code: String) -> bool:
	calibration.last_rejection = code
	rejected.emit(code)
	_refresh_status()
	return false

func _refresh_status() -> void:
	status_label.text = "%d/8 %s%s" % [step_index + 1, step_names[step_index], "" if calibration.last_rejection.is_empty() else ": " + calibration.last_rejection]
	action_button.visible = step_index in [0, 1, 7]
	if step_index == 0:
		action_button.text = "DETECT DEVICE"
	elif step_index == 1:
		action_button.text = "START LIVE MONITOR"
	elif step_index == 7:
		action_button.text = "RUN HOVER TEST"
