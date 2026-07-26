class_name CollisionProbeBody
extends RigidBody3D

var contact_seen := false
var contact_normal := Vector3.ZERO
var contact_impulse := Vector3.ZERO
var pending_native_state := false
var native_position := Vector3.ZERO
var native_orientation := Quaternion.IDENTITY
var native_linear_velocity := Vector3.ZERO
var native_angular_velocity := Vector3.ZERO
var native_body_angular_velocity := Vector3.ZERO
var _pending_reset_token := 0
var _acknowledged_reset_token := 0

func reset_contact() -> void:
    contact_seen = false
    contact_normal = Vector3.ZERO
    contact_impulse = Vector3.ZERO

func apply_native_state(
    position: Vector3,
    orientation: Quaternion,
    linear: Vector3,
    angular: Vector3
) -> void:
    _queue_native_state(position, orientation, linear, angular, 0)


func queue_reset_state(position: Vector3, orientation: Quaternion, token: int) -> int:
    if token <= 0:
        return 0
    _queue_native_state(position, orientation, Vector3.ZERO, Vector3.ZERO, token)
    return token


func reset_acknowledged(token: int) -> bool:
    return token > 0 and _acknowledged_reset_token >= token


func _queue_native_state(
    position: Vector3,
    orientation: Quaternion,
    linear: Vector3,
    angular: Vector3,
    reset_token: int
) -> void:
    native_position = position
    native_orientation = orientation.normalized()
    native_linear_velocity = linear
    native_body_angular_velocity = angular
    native_angular_velocity = Basis(native_orientation) * angular
    _pending_reset_token = reset_token
    pending_native_state = true

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
    if pending_native_state:
        state.transform = Transform3D(Basis(native_orientation), native_position)
        state.linear_velocity = native_linear_velocity
        state.angular_velocity = native_angular_velocity
        pending_native_state = false
        if _pending_reset_token > 0:
            _acknowledged_reset_token = _pending_reset_token
            _pending_reset_token = 0

    if state.get_contact_count() <= 0:
        return
    contact_seen = true
    contact_normal = (state.transform.basis * state.get_contact_local_normal(0)).normalized()
    if state.has_method("get_contact_impulse"):
        var impulse = state.call("get_contact_impulse", 0)
        if typeof(impulse) == TYPE_VECTOR3:
            contact_impulse = impulse
