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


class KeyboardProfile:
    const NAME := "KeyboardProfile"
    const DEFAULT_ACTIONS := {
        "pause": "P",
        "reset": "R",
        "change_spawn": "SHIFT+R",
        "exit": "ESC",
        "arm": "T",
        "mode": "C",
        "view": "V",
    }


class ActionContract:
    const ACTIONS := ["pause", "reset", "change_spawn", "exit", "arm", "mode", "view"]
    const GAMEPAD_DEFAULT_ACTIONS := {
        "pause": "START",
        "reset": "X",
        "change_spawn": "START+X",
        "exit": "B",
        "arm": "A",
        "mode": "Y",
        "view": "BACK",
    }
    const KEYBOARD_INPUT_ACTIONS := {
        "flight_takeoff": {"keycode": KEY_T, "shift_pressed": false},
        "flight_pause": {"keycode": KEY_P, "shift_pressed": false},
        "flight_respawn": {"keycode": KEY_R, "shift_pressed": false},
        "flight_change_spawn": {"keycode": KEY_R, "shift_pressed": true},
        "flight_altitude_hold": {"keycode": KEY_H, "shift_pressed": false},
        "flight_acro": {"keycode": KEY_C, "shift_pressed": false},
        "flight_exit": {"keycode": KEY_ESCAPE, "shift_pressed": false},
        "flight_view_toggle": {"keycode": KEY_V, "shift_pressed": false},
    }
    const GAMEPAD_INPUT_ACTIONS := {
        "flight_takeoff": JOY_BUTTON_A,
        "flight_pause": JOY_BUTTON_START,
        "flight_respawn": JOY_BUTTON_X,
        "flight_altitude_hold": JOY_BUTTON_Y,
        "flight_acro": GamepadProfile.ACRO_BUTTON,
        "flight_exit": JOY_BUTTON_B,
        "flight_view_toggle": JOY_BUTTON_BACK,
    }

    static func default_bindings(profile_name: String) -> Dictionary:
        if profile_name == KeyboardProfile.NAME:
            return KeyboardProfile.DEFAULT_ACTIONS.duplicate()
        if profile_name == "GamepadProfile":
            return GAMEPAD_DEFAULT_ACTIONS.duplicate()
        return {}

    static func validate_bindings(bindings: Dictionary) -> Dictionary:
        var seen := {}
        for action in ACTIONS:
            if not bindings.has(action):
                return {"ok": false, "error": "missing action binding: %s" % action}
            if typeof(bindings[action]) != TYPE_STRING:
                return {"ok": false, "error": "action binding must be a string: %s" % action}
            var binding := String(bindings[action])
            if binding.is_empty() or binding == "UNBOUND":
                return {"ok": false, "error": "unbound action: %s" % action}
            if seen.has(binding):
                return {"ok": false, "error": "action conflict: %s and %s use %s" % [seen[binding], action, binding]}
            seen[binding] = action
        return {"ok": true, "error": ""}

    static func validate_input_map() -> Dictionary:
        for profile_name in [KeyboardProfile.NAME, "GamepadProfile"]:
            var binding_result := validate_bindings(default_bindings(profile_name))
            if not binding_result.ok:
                return binding_result
        for action in KEYBOARD_INPUT_ACTIONS:
            if not InputMap.has_action(action):
                return {"ok": false, "error": "missing InputMap action: %s" % action}
            var expected: Dictionary = KEYBOARD_INPUT_ACTIONS[action]
            var key_match_count := 0
            for mapped_event in InputMap.action_get_events(action):
                if mapped_event is InputEventKey:
                    var key_event := mapped_event as InputEventKey
                    var key_matches: bool = key_event.keycode == expected.keycode and key_event.physical_keycode == expected.keycode
                    key_matches = key_matches and key_event.shift_pressed == expected.shift_pressed and not key_event.alt_pressed and not key_event.ctrl_pressed and not key_event.meta_pressed
                    if not key_matches:
                        return {"ok": false, "error": "non-canonical keyboard binding: %s" % action}
                    key_match_count += 1
                elif mapped_event is InputEventJoypadButton:
                    if not GAMEPAD_INPUT_ACTIONS.has(action) or int(mapped_event.button_index) != int(GAMEPAD_INPUT_ACTIONS[action]):
                        return {"ok": false, "error": "non-canonical gamepad binding: %s" % action}
                else:
                    return {"ok": false, "error": "unsupported InputMap event: %s" % action}
            if key_match_count != 1:
                return {"ok": false, "error": "duplicate/missing keyboard binding: %s" % action}
        for action in GAMEPAD_INPUT_ACTIONS:
            if not InputMap.has_action(action):
                return {"ok": false, "error": "missing InputMap action: %s" % action}
            var joy_match_count := 0
            for mapped_event in InputMap.action_get_events(action):
                if mapped_event is InputEventJoypadButton:
                    if int(mapped_event.button_index) != int(GAMEPAD_INPUT_ACTIONS[action]):
                        return {"ok": false, "error": "non-canonical gamepad binding: %s" % action}
                    joy_match_count += 1
                elif not mapped_event is InputEventKey:
                    return {"ok": false, "error": "unsupported InputMap event: %s" % action}
            if joy_match_count != 1:
                return {"ok": false, "error": "duplicate/missing gamepad binding: %s" % action}
        return {"ok": true, "error": ""}

    static func glyph(bindings: Dictionary, action: String) -> String:
        return String(bindings.get(action, "UNBOUND"))

static func fallback_status(connected_joypads: Array) -> String:
    if connected_joypads.is_empty():
        return "No controller detected; KeyboardProfile fallback active (non-sim control)"
    return "GamepadProfile active (non-sim control)"
