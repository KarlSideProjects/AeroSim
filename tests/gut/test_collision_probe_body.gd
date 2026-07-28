extends GutTest

const CollisionProbeBody = preload("res://common/flight/collision_probe_body.gd")


func test_reset_pose_waits_for_one_physics_commit_and_acknowledges_its_token() -> void:
    var body := CollisionProbeBody.new()
    body.gravity_scale = 0.0
    body.freeze = false
    get_tree().root.add_child(body)
    autofree(body)
    # Let the body reach the physics server before the reset is queued. A body
    # added mid-frame is not guaranteed to be simulated in the step that follows,
    # so without this the single commit awaited below can be a step in which
    # `_integrate_forces` never ran: the pattern misses roughly a third of the
    # time in isolation. Settling first is what makes the awaited frame the
    # commit frame this test is about.
    await get_tree().physics_frame

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
