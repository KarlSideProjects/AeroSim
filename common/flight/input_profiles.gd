class GamepadProfile:
    const SCHEMA_VERSION := 1
    const RAW_AXIS_DEADZONE := 0.08
    const THROTTLE_LOW_THRESHOLD := RAW_AXIS_DEADZONE
    const ACRO_BUTTON := JOY_BUTTON_RIGHT_SHOULDER

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
        if not device_state.is_joy_known(device_id):
            return false
        var name: String = str(device_state.joy_name(device_id)).to_lower()
        return name.contains("xbox") or name.contains("xinput") or name.contains("x-input")

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

    func to_persisted_dict() -> Dictionary:
        return {
            "profile_schema_version": profile_schema_version,
            "axis_for_role": axis_for_role.duplicate(true),
            "reversed_for_role": reversed_for_role.duplicate(true),
            "arm_button": arm_button,
            "mode_button": mode_button,
            "deadzone": deadzone,
        }

    static func validate_persisted_dict(candidate: Variant) -> Dictionary:
        if typeof(candidate) != TYPE_DICTIONARY:
            return {"ok": false, "error": "confirmed_gamepad must be an object"}
        var source: Dictionary = candidate
        var fields := ["profile_schema_version", "axis_for_role", "reversed_for_role", "arm_button", "mode_button", "deadzone"]
        for key in source.keys():
            if not fields.has(key):
                return {"ok": false, "error": "unknown confirmed_gamepad field: %s" % key}
        for key in fields:
            if not source.has(key):
                return {"ok": false, "error": "missing confirmed_gamepad field: %s" % key}
        if typeof(source["profile_schema_version"]) != TYPE_INT or int(source["profile_schema_version"]) != SCHEMA_VERSION:
            return {"ok": false, "error": "unsupported confirmed_gamepad schema"}
        if typeof(source["axis_for_role"]) != TYPE_DICTIONARY or typeof(source["reversed_for_role"]) != TYPE_DICTIONARY:
            return {"ok": false, "error": "confirmed_gamepad mappings must be objects"}
        var expected_axes := {"roll": JOY_AXIS_LEFT_X, "pitch": JOY_AXIS_LEFT_Y, "yaw": JOY_AXIS_RIGHT_X, "throttle": JOY_AXIS_RIGHT_Y}
        var expected_reversed := {"roll": false, "pitch": true, "yaw": false, "throttle": false}
        for role in source["axis_for_role"].keys():
            if not expected_axes.has(role):
                return {"ok": false, "error": "unknown confirmed_gamepad axis role: %s" % role}
        for role in source["reversed_for_role"].keys():
            if not expected_reversed.has(role):
                return {"ok": false, "error": "unknown confirmed_gamepad reverse role: %s" % role}
        for role in ["roll", "pitch", "yaw", "throttle"]:
            if not source["axis_for_role"].has(role) or not source["reversed_for_role"].has(role):
                return {"ok": false, "error": "confirmed_gamepad mapping is incomplete"}
            if typeof(source["axis_for_role"][role]) != TYPE_INT or int(source["axis_for_role"][role]) != expected_axes[role]:
                return {"ok": false, "error": "confirmed_gamepad axis mapping is not canonical"}
            if typeof(source["reversed_for_role"][role]) != TYPE_BOOL or source["reversed_for_role"][role] != expected_reversed[role]:
                return {"ok": false, "error": "confirmed_gamepad reverse mapping is not canonical"}
        if typeof(source["arm_button"]) != TYPE_INT or typeof(source["mode_button"]) != TYPE_INT:
            return {"ok": false, "error": "confirmed_gamepad buttons must be integers"}
        if int(source["arm_button"]) != JOY_BUTTON_A or int(source["mode_button"]) != JOY_BUTTON_Y:
            return {"ok": false, "error": "confirmed_gamepad buttons are not canonical"}
        if typeof(source["deadzone"]) not in [TYPE_INT, TYPE_FLOAT] or not is_equal_approx(float(source["deadzone"]), RAW_AXIS_DEADZONE):
            return {"ok": false, "error": "confirmed_gamepad deadzone is not canonical"}
        return {"ok": true, "error": ""}

    static func from_persisted_dict(candidate: Variant) -> GamepadProfile:
        var result := validate_persisted_dict(candidate)
        if not result.ok:
            return null
        var source: Dictionary = candidate
        var profile := GamepadProfile.new()
        profile.profile_schema_version = int(source["profile_schema_version"])
        profile.axis_for_role = source["axis_for_role"].duplicate(true)
        profile.reversed_for_role = source["reversed_for_role"].duplicate(true)
        profile.arm_button = int(source["arm_button"])
        profile.mode_button = int(source["mode_button"])
        profile.deadzone = float(source["deadzone"])
        return profile

static func fallback_status(connected_joypads: Array) -> String:
    if connected_joypads.is_empty():
        return "No controller detected; KeyboardProfile fallback active (non-sim control)"
    return "GamepadProfile active (non-sim control)"
