extends GutTest

const AirSimCoordinateContract = preload("res://common/rpc/airsim_coordinate_contract.gd")


func test_world_axes_are_explicitly_converted_between_godot_and_ned() -> void:
    assert_eq(AirSimCoordinateContract.godot_world_to_ned(Vector3.RIGHT), Vector3.RIGHT)
    assert_eq(AirSimCoordinateContract.godot_world_to_ned(Vector3.UP), Vector3.FORWARD)
    assert_eq(AirSimCoordinateContract.godot_world_to_ned(Vector3.FORWARD), Vector3(0.0, -1.0, 0.0))
    assert_eq(
        AirSimCoordinateContract.godot_world_to_ned(Vector3(1.0, 2.0, 3.0)),
        Vector3(1.0, 3.0, -2.0)
    )
    assert_eq(
        AirSimCoordinateContract.ned_to_godot_world(Vector3(1.0, 3.0, -2.0)),
        Vector3(1.0, 2.0, 3.0)
    )
    assert_eq(
        AirSimCoordinateContract.godot_world_to_ned(Vector3(-1.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0)),
        Vector3.ZERO
    )


func test_body_vectors_round_trip_without_exposing_godot_axes() -> void:
    var godot_body := Vector3(-0.4, 1.2, 2.5)
    var frd: Vector3 = AirSimCoordinateContract.godot_body_to_frd(godot_body)

    assert_eq(frd, Vector3(-0.4, 2.5, -1.2))
    assert_eq(AirSimCoordinateContract.frd_to_godot_body(frd), godot_body)


func test_orientation_and_angular_quantities_use_the_same_handed_conversion() -> void:
    var godot_orientation := Quaternion(Vector3(0.3, 0.7, -0.2).normalized(), 0.8).normalized()
    var ned_orientation: Quaternion = AirSimCoordinateContract.godot_orientation_to_ned(godot_orientation)
    var round_trip: Quaternion = AirSimCoordinateContract.ned_orientation_to_godot(ned_orientation)

    assert_almost_eq(absf(ned_orientation.x), absf(godot_orientation.x), 0.000001)
    assert_almost_eq(absf(ned_orientation.y), absf(godot_orientation.z), 0.000001)
    assert_almost_eq(absf(ned_orientation.z), absf(godot_orientation.y), 0.000001)
    assert_almost_eq(absf(ned_orientation.w), absf(godot_orientation.w), 0.000001)
    assert_almost_eq(absf(round_trip.dot(godot_orientation)), 1.0, 0.000001)

    var godot_yaw := Quaternion(Vector3.UP, PI / 2.0)
    var ned_yaw := AirSimCoordinateContract.godot_orientation_to_ned(godot_yaw)
    assert_almost_eq(ned_yaw.x, 0.0, 0.000001)
    assert_almost_eq(ned_yaw.y, 0.0, 0.000001)
    assert_true(ned_yaw.z < 0.0)

    var angular_rate := Vector3(0.1, -0.2, 0.3)
    var acceleration := Vector3(-1.0, 2.0, -3.0)
    var force := Vector3(4.0, -5.0, 6.0)
    assert_eq(AirSimCoordinateContract.godot_body_to_frd(angular_rate), Vector3(0.1, 0.3, 0.2))
    assert_eq(AirSimCoordinateContract.godot_world_to_ned(acceleration), Vector3(-1.0, -3.0, -2.0))
    assert_eq(AirSimCoordinateContract.godot_body_to_frd(force), Vector3(4.0, 6.0, 5.0))


func test_yaw_is_reported_in_ned_degrees_with_positive_downstream_rotation() -> void:
    assert_almost_eq(
        AirSimCoordinateContract.godot_yaw_radians_to_ned_degrees(PI / 2.0),
        -90.0,
        0.000001
    )
    assert_almost_eq(
        AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(90.0),
        -PI / 2.0,
        0.000001
    )


func test_ned_orientation_reports_zyx_roll_pitch_yaw_in_degrees() -> void:
    var orientation := Quaternion(Vector3(0.0, 0.0, 1.0), deg_to_rad(30.0)) * \
        Quaternion(Vector3(0.0, 1.0, 0.0), deg_to_rad(-20.0)) * \
        Quaternion(Vector3(1.0, 0.0, 0.0), deg_to_rad(10.0))
    var euler: Dictionary = AirSimCoordinateContract.ned_orientation_to_zyx_euler_degrees(orientation)

    assert_almost_eq(float(euler.get("roll", 0.0)), 10.0, 0.0001)
    assert_almost_eq(float(euler.get("pitch", 0.0)), -20.0, 0.0001)
    assert_almost_eq(float(euler.get("yaw", 0.0)), 30.0, 0.0001)
