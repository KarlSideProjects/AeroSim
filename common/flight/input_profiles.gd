const Calibration = preload("res://common/flight/gamepad_calibration.gd")

class GamepadProfile:
    var deadzone := 0.05
    var throttle := 0.0
    var axis_for_role := {}
    var reversed_for_role := {}
    var axis_ranges := {}
    var arm_button := -1
    var mode_button := -1
    var sticky_throttle := true
    var profile_schema_version := 0

    static func from_calibration(profile: Calibration.CalibrationProfile) -> GamepadProfile:
        var gamepad := GamepadProfile.new()
        gamepad.axis_for_role = profile.axis_for_role.duplicate(true)
        gamepad.reversed_for_role = profile.reversed_for_role.duplicate(true)
        gamepad.axis_ranges = profile.axis_ranges.duplicate(true)
        gamepad.arm_button = profile.arm_button
        gamepad.mode_button = profile.mode_button
        gamepad.sticky_throttle = profile.sticky_throttle
        gamepad.profile_schema_version = profile.SCHEMA_VERSION
        return gamepad

    func apply_throttle_axis(value: float) -> void:
        if absf(value) <= deadzone:
            return
        throttle = clampf(value, 0.0, 1.0)

static func fallback_status(connected_joypads: Array) -> String:
    if connected_joypads.is_empty():
        return "No controller detected; KeyboardProfile fallback active (non-sim control)"
    return "GamepadProfile active (non-sim control)"
