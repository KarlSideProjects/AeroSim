class GamepadProfile:
    var deadzone := 0.05
    var throttle := 0.0

    func apply_throttle_axis(value: float) -> void:
        if absf(value) <= deadzone:
            return
        throttle = clampf(value, 0.0, 1.0)

static func fallback_status(connected_joypads: Array) -> String:
    if connected_joypads.is_empty():
        return "No controller detected; KeyboardProfile fallback active (non-sim control)"
    return "GamepadProfile active (non-sim control)"
