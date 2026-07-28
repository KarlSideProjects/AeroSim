class_name AirSimCoordinateContract
extends RefCounted

## The public AirSim boundary is NED world axes and FRD body axes, in SI units.
## AeroSim keeps Godot's Y-up representation internal. The native runtime's
## FRD basis is (x, y, z) -> (x, z, -y): internal X is forward, internal Z is
## right, and internal Y is up.


static func godot_world_to_ned(position: Vector3, godot_origin: Vector3 = Vector3.ZERO) -> Vector3:
    return _godot_to_external(position - godot_origin)


static func ned_to_godot_world(position: Vector3, godot_origin: Vector3 = Vector3.ZERO) -> Vector3:
    return _external_to_godot(position) + godot_origin


static func godot_direction_to_ned(direction: Vector3) -> Vector3:
    return _godot_to_external(direction)


static func ned_direction_to_godot(direction: Vector3) -> Vector3:
    return _external_to_godot(direction)


static func godot_body_to_frd(vector: Vector3) -> Vector3:
    return _godot_to_external(vector)


static func frd_to_godot_body(vector: Vector3) -> Vector3:
    return _external_to_godot(vector)


static func godot_orientation_to_ned(orientation: Quaternion) -> Quaternion:
    return Quaternion(orientation.x, orientation.z, -orientation.y, orientation.w).normalized()


static func ned_orientation_to_godot(orientation: Quaternion) -> Quaternion:
    return Quaternion(orientation.x, -orientation.z, orientation.y, orientation.w).normalized()


static func ned_orientation_to_zyx_euler_degrees(orientation: Quaternion) -> Array[float]:
    var euler := Basis(orientation).get_euler(EULER_ORDER_ZYX)
    return [rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z)]


static func godot_yaw_radians_to_ned_degrees(yaw_radians: float) -> float:
    return -rad_to_deg(yaw_radians)


static func ned_yaw_degrees_to_godot_radians(yaw_degrees: float) -> float:
    return -deg_to_rad(yaw_degrees)


static func _godot_to_external(vector: Vector3) -> Vector3:
    return Vector3(vector.x, vector.z, -vector.y)


static func _external_to_godot(vector: Vector3) -> Vector3:
    return Vector3(vector.x, -vector.z, vector.y)
