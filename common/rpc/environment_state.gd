class_name EnvironmentState
extends RefCounted

const DEFAULTS := {
    "wind_preset": "calm",
    "steady_wind": Vector3.ZERO,
    "rain": 0.0,
    "fog": 0.0,
    "weather_enabled": false,
    "time_of_day": 12.0,
    "time_of_day_enabled": false,
    "start_datetime": "",
    "is_start_datetime_dst": false,
    "celestial_clock_speed": 1.0,
    "update_interval_secs": 60.0,
    "move_sun": true,
    "sun_position": Vector3(0.0, 1.0, 0.0),
}
const KEYS := {
    "wind_preset": true,
    "steady_wind": true,
    "rain": true,
    "fog": true,
    "weather_enabled": true,
    "time_of_day": true,
    "time_of_day_enabled": true,
    "start_datetime": true,
    "is_start_datetime_dst": true,
    "celestial_clock_speed": true,
    "update_interval_secs": true,
    "move_sun": true,
    "sun_position": true,
}
const ALLOWED_WIND_PRESETS := ["calm", "light", "moderate", "severe"]

var revision: int = 0
var _state: Dictionary = DEFAULTS.duplicate(true)
signal changed(snapshot: Dictionary, revision: int)


func apply(raw: Dictionary) -> Dictionary:
    var candidate: Dictionary = _state.duplicate(true)
    var errors: Array[String] = []
    for key in raw.keys():
        if not KEYS.has(String(key)):
            errors.append("unknown environment key: %s" % key)
            continue
        candidate[String(key)] = raw[key]
    if candidate.get("sun_position") is Vector3 and candidate.sun_position.length_squared() > 0.0:
        candidate.sun_position = candidate.sun_position.normalized()
    _validate_field(candidate, "wind_preset", errors)
    _validate_field(candidate, "steady_wind", errors)
    _validate_field(candidate, "rain", errors)
    _validate_field(candidate, "fog", errors)
    _validate_field(candidate, "time_of_day", errors)
    _validate_field(candidate, "sun_position", errors)
    if not errors.is_empty():
        return {"ok": false, "error": "; ".join(errors)}
    _state = candidate
    revision += 1
    changed.emit(snapshot(), revision)
    return {"ok": true, "state": snapshot(), "revision": revision}


func snapshot() -> Dictionary:
    return _state.duplicate(true)


func reset() -> Dictionary:
    _state = DEFAULTS.duplicate(true)
    revision += 1
    changed.emit(snapshot(), revision)
    return {"ok": true, "state": snapshot(), "revision": revision}


func _validate_field(candidate: Dictionary, key: String, errors: Array[String]) -> void:
    var value = candidate.get(key)
    match key:
        "wind_preset":
            if typeof(value) != TYPE_STRING or not ALLOWED_WIND_PRESETS.has(String(value)):
                errors.append("wind_preset must be one of %s" % ", ".join(ALLOWED_WIND_PRESETS))
        "steady_wind", "sun_position":
            if not (value is Vector3) or not value.is_finite() or (key == "sun_position" and value.length_squared() <= 0.0):
                errors.append("%s must be a finite Vector3" % key)
        "rain", "fog":
            if (typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > 1.0:
                errors.append("%s must be in the range 0..1" % key)
        "weather_enabled", "time_of_day_enabled", "is_start_datetime_dst", "move_sun":
            if typeof(value) != TYPE_BOOL:
                errors.append("%s must be boolean" % key)
        "start_datetime":
            if typeof(value) != TYPE_STRING:
                errors.append("start_datetime must be a string")
        "celestial_clock_speed", "update_interval_secs":
            if (typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT) or not is_finite(float(value)) or float(value) <= 0.0:
                errors.append("%s must be positive and finite" % key)
        "time_of_day":
            if (typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT) or not is_finite(float(value)) or float(value) < 0.0 or float(value) >= 24.0:
                errors.append("time_of_day must be in the range 0..24")
