extends GutTest

const AirSimSession = preload("res://common/rpc/airsim_session.gd")


func test_paused_session_advances_only_when_explicitly_stepped() -> void:
    var session := AirSimSession.new(1000)
    session.set_paused(true)

    session.advance_frame()
    assert_eq(session.frame_index, 0)
    assert_almost_eq(session.simulation_time_seconds, 0.0, 0.000001)

    var result: Dictionary = session.continue_for_frames(3)
    assert_true(result.ok)
    assert_false(session.is_paused())
    session.advance_frame()
    session.advance_frame()
    session.advance_frame()
    assert_eq(session.frame_index, 3)
    assert_almost_eq(session.simulation_time_seconds, 0.003, 0.000001)
    assert_true(session.is_paused())


func test_duration_step_is_deterministic_and_rejects_invalid_duration() -> void:
    var session := AirSimSession.new(1000)
    session.set_paused(true)

    var result: Dictionary = session.continue_for_time(0.025)
    assert_true(result.ok)
    for _frame in 25:
        session.advance_frame()
    assert_eq(session.frame_index, 25)
    assert_almost_eq(session.simulation_time_seconds, 0.025, 0.000001)

    var rounded: Dictionary = session.continue_for_time(0.0005)
    assert_true(rounded.ok)
    session.advance_frame()
    assert_eq(session.frame_index, 26)

    var non_finite: Dictionary = session.continue_for_time(NAN)
    assert_false(non_finite.ok)
    assert_string_contains(non_finite.error, "duration step")

    var overlap_started: Dictionary = session.continue_for_frames(2)
    assert_true(overlap_started.ok)
    var overlap: Dictionary = session.continue_for_time(0.01)
    assert_false(overlap.ok)
    assert_string_contains(overlap.error, "already in progress")


func test_reset_restores_the_initial_clock_state() -> void:
    var session := AirSimSession.new(240)
    session.set_paused(true)
    session.continue_for_frames(10)
    session.reset()

    assert_eq(session.frame_index, 0)
    assert_almost_eq(session.simulation_time_seconds, 0.0, 0.000001)
    assert_false(session.is_paused())
