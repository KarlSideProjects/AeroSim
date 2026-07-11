class CalibrationProfile:
	const SCHEMA_VERSION := 1
	var axis_for_role: Dictionary
	var reversed_for_role: Dictionary
	var axis_ranges: Dictionary
	var arm_button := -1
	var mode_button := -1
	var sticky_throttle := true

	func to_dictionary() -> Dictionary:
		return {
			"schema_version": SCHEMA_VERSION,
			"axis_for_role": axis_for_role.duplicate(true),
			"reversed_for_role": reversed_for_role.duplicate(true),
			"axis_ranges": axis_ranges.duplicate(true),
			"arm_button": arm_button,
			"mode_button": mode_button,
			"sticky_throttle": sticky_throttle,
		}

class GamepadCalibration:
	const ROLES := ["roll", "pitch", "yaw", "throttle"]
	const MIN_ENDPOINT_COVERAGE := 0.95
	const ENDPOINT_COVERAGE_EPSILON := 0.0000001
	const MAX_CENTER_OFFSET := 0.02
	const MAX_STATIONARY_RMS := 0.005
	const DEFAULT_STATIONARY_SAMPLE_HZ := 100
	const MIN_STATIONARY_DURATION_SECONDS := 1
	const MAX_DEBOUNCE_MS := 50
	const MAX_THROTTLE_LOW := 0.02

	var axis_for_role := {}
	var reversed_for_role := {}
	var axis_ranges := {}
	var buttons := {}
	var last_button_press_ms := {}
	var last_rejection := ""

	func assign_axis(role: String, axis: int) -> bool:
		if not ROLES.has(role) or axis < 0 or axis_for_role.values().has(axis):
			last_rejection = "duplicate_axis"
			return false
		axis_for_role[role] = axis
		return true

	func record_axis_range(role: String, samples: PackedFloat32Array) -> bool:
		if not axis_for_role.has(role) or samples.is_empty():
			last_rejection = "endpoint_coverage"
			return false
		var minimum := samples[0]
		var maximum := samples[0]
		for value in samples:
			if not is_finite(value):
				last_rejection = "endpoint_coverage"
				return false
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
		if maximum < MIN_ENDPOINT_COVERAGE - ENDPOINT_COVERAGE_EPSILON or minimum > -MIN_ENDPOINT_COVERAGE + ENDPOINT_COVERAGE_EPSILON:
			last_rejection = "endpoint_coverage"
			return false
		axis_ranges[role] = {"minimum": minimum, "maximum": maximum}
		return true

	func record_stationary_samples(role: String, samples: PackedFloat32Array, sample_hz: int = DEFAULT_STATIONARY_SAMPLE_HZ) -> bool:
		if not axis_ranges.has(role) or samples.is_empty():
			last_rejection = "center_offset"
			return false
		if sample_hz <= 0 or samples.size() < sample_hz * MIN_STATIONARY_DURATION_SECONDS:
			last_rejection = "stationary_noise"
			return false
		var center := 0.0
		for value in samples:
			if not is_finite(value):
				last_rejection = "center_offset"
				return false
			center += value
		center /= samples.size()
		if absf(center) > MAX_CENTER_OFFSET:
			last_rejection = "center_offset"
			return false
		var variance := 0.0
		for value in samples:
			variance += pow(value - center, 2.0)
		if sqrt(variance / samples.size()) > MAX_STATIONARY_RMS:
			last_rejection = "stationary_noise"
			return false
		axis_ranges[role]["center"] = center
		return true

	func set_axis_direction(role: String, observed_value: float) -> bool:
		if not axis_for_role.has(role) or not is_finite(observed_value) or is_zero_approx(observed_value):
			last_rejection = "endpoint_coverage"
			return false
		reversed_for_role[role] = observed_value < 0.0
		return true

	func assign_button(role: String, button: int) -> bool:
		if not ["arm", "mode"].has(role) or button < 0 or buttons.values().has(button):
			last_rejection = "duplicate_button"
			return false
		buttons[role] = button
		return true

	func record_button_press(role: String, timestamp_ms: int) -> bool:
		if not buttons.has(role):
			last_rejection = "duplicate_button"
			return false
		if last_button_press_ms.has(role) and timestamp_ms - int(last_button_press_ms[role]) < MAX_DEBOUNCE_MS:
			last_rejection = "button_bounce"
			return false
		last_button_press_ms[role] = timestamp_ms
		return true

	func throttle_is_low(value: float) -> bool:
		if not is_finite(value) or value > MAX_THROTTLE_LOW:
			last_rejection = "throttle_not_low"
			return false
		return true

	func finish() -> CalibrationProfile:
		if axis_for_role.size() != 4 or axis_ranges.size() != 4 or reversed_for_role.size() != 4 or buttons.size() != 2:
			last_rejection = "incomplete_profile"
			return null
		var profile := CalibrationProfile.new()
		profile.axis_for_role = axis_for_role.duplicate(true)
		profile.reversed_for_role = reversed_for_role.duplicate(true)
		profile.axis_ranges = axis_ranges.duplicate(true)
		profile.arm_button = buttons.arm
		profile.mode_button = buttons.mode
		return profile
