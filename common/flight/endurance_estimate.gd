class_name EnduranceEstimate
extends RefCounted

const LOW_RATIO := 0.25
const CRITICAL_RATIO := 0.10

var _total_seconds := 0.0
var _remaining_seconds := 0.0
var _last_timestamp_us := -1
var _was_armed := false


func configure(total_seconds: float) -> void:
    _total_seconds = maxf(0.0, total_seconds)
    _remaining_seconds = _total_seconds
    _last_timestamp_us = -1
    _was_armed = false


func reset() -> void:
    _remaining_seconds = _total_seconds
    _last_timestamp_us = -1
    _was_armed = false


func update(timestamp_us: int, armed: bool) -> Dictionary:
    if _total_seconds <= 0.0:
        return _snapshot("unavailable")
    if _last_timestamp_us >= 0 and timestamp_us >= _last_timestamp_us and _was_armed:
        _remaining_seconds = maxf(0.0, _remaining_seconds - float(timestamp_us - _last_timestamp_us) / 1_000_000.0)
    _last_timestamp_us = timestamp_us
    _was_armed = armed
    return _snapshot("expired" if _remaining_seconds <= 0.0 else "ready")


func _snapshot(state: String) -> Dictionary:
    var ratio := _remaining_seconds / _total_seconds if _total_seconds > 0.0 else 0.0
    var severity := "critical" if ratio <= CRITICAL_RATIO else "low" if ratio <= LOW_RATIO else "normal"
    return {
        "state": state,
        "total_seconds": _total_seconds,
        "remaining_seconds": _remaining_seconds,
        "ratio": ratio,
        "severity": severity,
    }
