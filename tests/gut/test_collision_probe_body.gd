extends GutTest

const CollisionProbeBody = preload("res://common/flight/collision_probe_body.gd")


func test_reset_pose_waits_for_one_physics_commit_and_acknowledges_its_token() -> void:
    var body := CollisionProbeBody.new()
    body.gravity_scale = 0.0
    body.freeze = false
    get_tree().root.add_child(body)
    autofree(body)

    var target_position := Vector3(4.0, 2.0, -3.0)
    var token: int = int(body.call("queue_reset_state", target_position, Quaternion.IDENTITY, 41))

    assert_eq(body.global_position, Vector3.ZERO)
    assert_false(bool(body.call("reset_acknowledged", token)))

    await get_tree().physics_frame
    await get_tree().process_frame

    assert_true(bool(body.call("reset_acknowledged", token)))
    assert_eq(body.global_position, target_position)
    assert_eq(body.linear_velocity, Vector3.ZERO)
    assert_eq(body.angular_velocity, Vector3.ZERO)
