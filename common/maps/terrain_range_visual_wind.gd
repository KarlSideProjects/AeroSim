class_name TerrainRangeVisualWind
extends Node

const CALM_SPEED_MPS := 0.001
const SMOOTHING_SECONDS := 1.0
const MAX_TURBULENCE_RATIO := 0.25
const MAX_VISUAL_SPEED_MPS := 10.0
# Covers the 0.62 m blade scale plus 0.06 m placement offset and the <0.43 m tip bend.
const PARTICLE_AABB_MARGIN_METERS := 0.75

@export var process_material: ShaderMaterial
@export var blade_material: ShaderMaterial
@export var sample_marker: NodePath = NodePath("../VisualWindSample")
@export var sample_position := Vector3(480.0, 79.7, -740.0)
@export var particle_grid: NodePath = NodePath("../Terrain3D/Terrain3DParticles")

var _accepted_simulation_time_seconds := -1.0
var _target_horizontal_wind := Vector2.ZERO
var _smoothed_horizontal_wind := Vector2.ZERO
var _phase := 0.0
var _last_direction := Vector2(-1.0, 1.0).normalized()
var _particle_bounds_expanded := false


func _ready() -> void:
    call_deferred("_expand_particle_bounds")


func advance(native: Object, simulation_time_seconds: float, active: bool) -> void:
    if not active or native == null or not is_finite(simulation_time_seconds):
        return
    var position := _sample_position()
    var sampled: Variant = native.call("sample_wind", simulation_time_seconds, position.x, position.y, position.z)
    if not (sampled is Vector3) or not (sampled as Vector3).is_finite():
        return
    var steady := _sampled_steady_wind(native, position)
    var prevailing := Vector2(steady.x, steady.z)
    var sampled_horizontal := Vector2((sampled as Vector3).x, (sampled as Vector3).z)
    _target_horizontal_wind = _bounded_visual_wind(prevailing, sampled_horizontal - prevailing)
    if _target_horizontal_wind.length_squared() > CALM_SPEED_MPS * CALM_SPEED_MPS:
        _last_direction = _target_horizontal_wind.normalized()
    if _accepted_simulation_time_seconds >= 0.0 and simulation_time_seconds < _accepted_simulation_time_seconds:
        _smoothed_horizontal_wind = Vector2.ZERO
        _phase = 0.0
    elif _accepted_simulation_time_seconds >= 0.0:
        var delta := simulation_time_seconds - _accepted_simulation_time_seconds
        var blend := 1.0 - exp(-maxf(delta, 0.0) / SMOOTHING_SECONDS)
        _smoothed_horizontal_wind = _smoothed_horizontal_wind.lerp(_target_horizontal_wind, blend)
        _phase += delta * _smoothed_horizontal_wind.length()
    _accepted_simulation_time_seconds = simulation_time_seconds
    _apply_shader_parameters()


func snapshot() -> Dictionary:
    return {
        "accepted_simulation_time_seconds": _accepted_simulation_time_seconds,
        "sample_position": _sample_position(),
        "target_horizontal_wind": _target_horizontal_wind,
        "smoothed_horizontal_wind": _smoothed_horizontal_wind,
        "phase": _phase,
    }


func _sample_position() -> Vector3:
    var marker := get_node_or_null(sample_marker) as Marker3D
    return marker.global_position if marker != null else sample_position


func _sampled_steady_wind(native: Object, position: Vector3) -> Vector3:
    var config: Variant = native.call("wind_configuration")
    if not (config is Dictionary):
        return Vector3.ZERO
    var dictionary := config as Dictionary
    var steady: Variant = dictionary.get("steady_wind", Vector3.ZERO)
    if not (steady is Vector3) or not (steady as Vector3).is_finite():
        return Vector3.ZERO
    var sampled_steady := steady as Vector3
    if bool(dictionary.get("shear_enabled", false)):
        var reference := float(dictionary.get("shear_reference_height_m", 1.0))
        var exponent := float(dictionary.get("shear_exponent", 0.0))
        if is_finite(reference) and reference > 0.0 and is_finite(exponent):
            var scale := pow(maxf(position.y, reference) / reference, exponent)
            sampled_steady.x *= scale
            sampled_steady.z *= scale
    return sampled_steady


func _bounded_visual_wind(prevailing: Vector2, turbulence: Vector2) -> Vector2:
    var speed := prevailing.length()
    if speed < CALM_SPEED_MPS:
        return Vector2.ZERO
    var capped_turbulence := turbulence.limit_length(speed * MAX_TURBULENCE_RATIO)
    return prevailing + capped_turbulence


func _apply_shader_parameters() -> void:
    var direction := _smoothed_horizontal_wind.normalized() if _smoothed_horizontal_wind.length_squared() > CALM_SPEED_MPS * CALM_SPEED_MPS else _last_direction
    var force := clampf(_smoothed_horizontal_wind.length() / MAX_VISUAL_SPEED_MPS, 0.0, 1.0)
    for material in [process_material, blade_material]:
        if material == null:
            continue
        material.set_shader_parameter("wind_direction", direction)
        material.set_shader_parameter("wind_force", force)
        material.set_shader_parameter("wind_phase", _phase)


func _expand_particle_bounds() -> void:
    if _particle_bounds_expanded:
        return
    var grid := get_node_or_null(particle_grid)
    if grid == null:
        return
    for child in grid.get_children():
        var particles := child as GPUParticles3D
        if particles != null:
            particles.custom_aabb = particles.custom_aabb.grow(PARTICLE_AABB_MARGIN_METERS)
    _particle_bounds_expanded = true
