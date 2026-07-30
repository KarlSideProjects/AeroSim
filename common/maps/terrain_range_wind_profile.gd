extends RefCounted

const PRESET_SPEEDS := {
    "calm": 0.0,
    "light": 2.0,
    "moderate": 5.0,
    "severe": 8.0,
}
const PREVAILING_DIRECTION := Vector3(-1.0, 0.0, 1.0)


static func speed_for_preset(preset: String) -> float:
    return float(PRESET_SPEEDS.get(preset, 0.0))


static func steady_wind_for_preset(preset: String) -> Vector3:
    return PREVAILING_DIRECTION.normalized() * speed_for_preset(preset)
