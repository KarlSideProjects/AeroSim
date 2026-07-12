class GamepadProfile:
    const SCHEMA_VERSION := 1
    const RAW_AXIS_DEADZONE := 0.08
    const THROTTLE_LOW_THRESHOLD := RAW_AXIS_DEADZONE

    var deadzone := RAW_AXIS_DEADZONE
    var throttle := 0.0
    var axis_for_role := {"roll": JOY_AXIS_LEFT_X, "pitch": JOY_AXIS_LEFT_Y, "yaw": JOY_AXIS_RIGHT_X, "throttle": JOY_AXIS_RIGHT_Y}
    var reversed_for_role := {"roll": false, "pitch": true, "yaw": false, "throttle": false}
    var arm_button := JOY_BUTTON_A
    var mode_button := JOY_BUTTON_Y
    var sticky_throttle := true
    var profile_schema_version := SCHEMA_VERSION
    var arm_pressed := false
    var mode_pressed := false

    static func is_supported_device(device_id: int, device_state: Object) -> bool:
        return device_state.is_joy_known(device_id)

    static func xbox_default(device_id: int, device_state: Object) -> GamepadProfile:
        if not is_supported_device(device_id, device_state):
            return null
        var gamepad := GamepadProfile.new()
        gamepad.axis_for_role = {"roll": JOY_AXIS_LEFT_X, "pitch": JOY_AXIS_LEFT_Y, "yaw": JOY_AXIS_RIGHT_X, "throttle": JOY_AXIS_RIGHT_Y}
        gamepad.reversed_for_role = {"roll": false, "pitch": true, "yaw": false, "throttle": false}
        gamepad.arm_button = JOY_BUTTON_A
        gamepad.mode_button = JOY_BUTTON_Y
        return gamepad

    func apply_throttle_axis(value: float) -> void:
        if absf(value) <= RAW_AXIS_DEADZONE:
            return
        throttle = clampf(value, 0.0, 1.0)

    func throttle_axis_is_low(value: float) -> bool:
        return value <= THROTTLE_LOW_THRESHOLD

static func fallback_status(connected_joypads: Array) -> String:
    if connected_joypads.is_empty():
        return "No controller detected; KeyboardProfile fallback active (non-sim control)"
    return "GamepadProfile active (non-sim control)"
