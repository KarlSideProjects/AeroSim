class_name AirSimSession
extends RefCounted

const MAX_EXPLICIT_STEP_FRAMES: int = 1_000_000

var physics_hz: int
var frame_index: int = 0
var simulation_time_seconds: float = 0.0

var _paused: bool = false


func _init(new_physics_hz: int = 240) -> void:
    physics_hz = new_physics_hz


func set_paused(value: bool) -> void:
    _paused = value


func is_paused() -> bool:
    return _paused


func advance_frame() -> bool:
    if _paused:
        return false
    _advance_frames(1)
    return true


func continue_for_frames(frames: int) -> Dictionary:
    if not _paused:
        return _error("simulation must be paused before explicit stepping")
    if frames < 0 or frames > MAX_EXPLICIT_STEP_FRAMES:
        return _error("frame step must be from 0 to %d" % MAX_EXPLICIT_STEP_FRAMES)
    _advance_frames(frames)
    return _step_result(frames)


func continue_for_time(seconds: float) -> Dictionary:
    if not _paused:
        return _error("simulation must be paused before explicit stepping")
    if not is_finite(seconds) or seconds < 0.0:
        return _error("duration step must not be negative")
    var exact_frames := seconds * float(physics_hz)
    var frames := roundi(exact_frames)
    if absf(exact_frames - float(frames)) > 0.000001:
        return _error("duration must resolve to whole simulation frames")
    if frames > MAX_EXPLICIT_STEP_FRAMES:
        return _error("duration step is too large")
    _advance_frames(frames)
    return _step_result(frames)


func reset() -> void:
    frame_index = 0
    simulation_time_seconds = 0.0
    _paused = false


func _advance_frames(frames: int) -> void:
    frame_index += frames
    simulation_time_seconds = float(frame_index) / float(physics_hz)


func _step_result(frames: int) -> Dictionary:
    return {
        "ok": true,
        "frames": frames,
        "frame_index": frame_index,
        "simulation_time_seconds": simulation_time_seconds,
    }


func _error(message: String) -> Dictionary:
    return {"ok": false, "error": message}
