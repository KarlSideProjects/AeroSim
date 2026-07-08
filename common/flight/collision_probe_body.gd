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
    native_position = position
    native_orientation = orientation.normalized()
    native_linear_velocity = linear
    native_angular_velocity = angular
    global_transform = Transform3D(Basis(native_orientation), native_position)
    linear_velocity = native_linear_velocity
    angular_velocity = native_angular_velocity
    pending_native_state = true

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
    if pending_native_state:
        state.transform = Transform3D(Basis(native_orientation), native_position)
        state.linear_velocity = native_linear_velocity
        state.angular_velocity = native_angular_velocity
        pending_native_state = false

    if state.get_contact_count() <= 0:
        return
    contact_seen = true
    contact_normal = (global_transform.basis * state.get_contact_local_normal(0)).normalized()
    if state.has_method("get_contact_impulse"):
        var impulse = state.call("get_contact_impulse", 0)
        if typeof(impulse) == TYPE_VECTOR3:
            contact_impulse = impulse
