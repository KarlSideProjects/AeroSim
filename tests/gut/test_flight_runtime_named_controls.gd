extends GutTest

const FlightRuntime = preload("res://common/flight/flight_runtime.gd")

class FakeBody extends RefCounted:
    var linear_velocity := Vector3.ZERO
    var rotation := Vector3.ZERO
    var global_transform := Transform3D.IDENTITY


func _body(velocity: Vector3, yaw: float) -> FakeBody:
    var result := FakeBody.new()
    result.linear_velocity = velocity
    result.rotation.y = yaw
    return result


func test_named_velocity_controller_uses_the_selected_body_for_measurement_and_yaw() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary := _body(Vector3.ZERO, 0.0)
    var secondary := _body(Vector3(4.0, 0.0, 0.0), PI * 0.5)
    var yaw_mode := {"yaw_or_rate": 0.0, "is_rate": false}

    var primary_controls: Dictionary = runtime._airsim_velocity_controls(Vector3.ZERO, 0.0, yaw_mode, primary)
    var secondary_controls: Dictionary = runtime._airsim_velocity_controls(Vector3.ZERO, 0.0, yaw_mode, secondary)

    assert_eq(primary_controls.roll, 0.0)
    assert_gt(secondary_controls.roll, 1.0)
    assert_eq(primary_controls.yaw_rate, 0.0)
    assert_lt(secondary_controls.yaw_rate, -1.0)
