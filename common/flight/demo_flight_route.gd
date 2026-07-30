class_name DemoFlightRoute
extends RefCounted

const HOVER_END_SECONDS := 30.0
const LOW_PASS_END_SECONDS := 50.0
const ORBIT_END_SECONDS := 115.0
const CLIMB_END_SECONDS := 135.0
const RETURN_END_SECONDS := 165.0
const LAND_END_SECONDS := 180.0
const CRUISE_SPEED_MPS := 4.0
const CLIMB_SPEED_MPS := 4.0
const LAND_SPEED_MPS := 4.0

var _spawn := Vector3.ZERO
var _elapsed_seconds := 0.0
var _active := false
var _complete := false


func start(spawn: Vector3) -> void:
    _spawn = spawn
    _elapsed_seconds = 0.0
    _active = true
    _complete = false


func cancel() -> void:
    _active = false


func advance(delta: float, position: Vector3, velocity: Vector3, _yaw_radians: float) -> Dictionary:
    if _active:
        _elapsed_seconds = minf(_elapsed_seconds + maxf(delta, 0.0), LAND_END_SECONDS)
        if _elapsed_seconds >= LAND_END_SECONDS - 0.0001 and position.distance_to(_spawn) <= 0.5 and velocity.length() <= 0.25:
            _elapsed_seconds = LAND_END_SECONDS
            _active = false
            _complete = true
    return snapshot()


func snapshot() -> Dictionary:
    if _complete:
        return _state("complete", _spawn, 0.0)
    if not _active:
        return _state("cancelled", _spawn, 0.0)
    if _elapsed_seconds < HOVER_END_SECONDS:
        return _state("hover", _hover_target(), 0.0)
    if _elapsed_seconds < LOW_PASS_END_SECONDS:
        return _state("low_pass", _interpolate(_hover_target(), _low_pass_target(), HOVER_END_SECONDS, LOW_PASS_END_SECONDS), CRUISE_SPEED_MPS)
    if _elapsed_seconds < ORBIT_END_SECONDS:
        return _state("orbit", _orbit_target(), CRUISE_SPEED_MPS)
    if _elapsed_seconds < CLIMB_END_SECONDS:
        return _state("climb", _interpolate(_orbit_finish(), _climb_target(), ORBIT_END_SECONDS, CLIMB_END_SECONDS), CLIMB_SPEED_MPS)
    if _elapsed_seconds < RETURN_END_SECONDS:
        return _state("return", _interpolate(_climb_target(), _return_target(), CLIMB_END_SECONDS, RETURN_END_SECONDS), CRUISE_SPEED_MPS)
    return _state("land", _interpolate(_return_target(), _spawn, RETURN_END_SECONDS, LAND_END_SECONDS), LAND_SPEED_MPS)


func _state(phase: String, target_position: Vector3, target_speed_mps: float) -> Dictionary:
    return {
        "phase": phase,
        "active": _active,
        "complete": _complete,
        "target_position": target_position,
        "target_speed_mps": target_speed_mps,
        "yaw_rate_dps": 0.0,
    }


func _hover_target() -> Vector3:
    return _spawn + Vector3(0.0, 12.0, 0.0)


func _low_pass_target() -> Vector3:
    return _spawn + Vector3(-10.0, 12.0, 35.0)


func _orbit_target() -> Vector3:
    var orbit_points := _orbit_points()
    var total_distance := 0.0
    for index in range(orbit_points.size() - 1):
        total_distance += orbit_points[index].distance_to(orbit_points[index + 1])
    var remaining_distance := total_distance * inverse_lerp(LOW_PASS_END_SECONDS, ORBIT_END_SECONDS, _elapsed_seconds)
    for index in range(orbit_points.size() - 1):
        var segment_length := orbit_points[index].distance_to(orbit_points[index + 1])
        if remaining_distance <= segment_length:
            return orbit_points[index].lerp(orbit_points[index + 1], remaining_distance / segment_length)
        remaining_distance -= segment_length
    return orbit_points.back()


func _orbit_points() -> Array[Vector3]:
    return [
        _low_pass_target(),
        _spawn + Vector3(5.0, 14.0, 55.0),
        _spawn + Vector3(25.0, 15.0, 65.0),
        _spawn + Vector3(50.0, 16.0, 58.0),
        _spawn + Vector3(60.0, 16.0, 35.0),
        _spawn + Vector3(55.0, 16.0, 5.0),
        _spawn + Vector3(15.0, 16.0, 0.0),
        _spawn + Vector3(-10.0, 15.0, 20.0),
        _spawn + Vector3(-15.0, 14.0, 40.0),
        _orbit_finish(),
    ]


func _orbit_finish() -> Vector3:
    return _spawn + Vector3(-20.0, 14.0, 55.0)


func _climb_target() -> Vector3:
    return _spawn + Vector3(-50.0, 20.0, 95.0)


func _return_target() -> Vector3:
    return _spawn + Vector3(8.0, 5.0, 8.0)


func _interpolate(start: Vector3, finish: Vector3, start_time: float, finish_time: float) -> Vector3:
    return start.lerp(finish, inverse_lerp(start_time, finish_time, _elapsed_seconds))
