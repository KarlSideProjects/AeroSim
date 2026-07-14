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
    assert_eq(session.frame_index, 3)
    assert_almost_eq(session.simulation_time_seconds, 0.003, 0.000001)
    assert_true(session.is_paused())


func test_duration_step_is_deterministic_and_rejects_invalid_duration() -> void:
    var session := AirSimSession.new(1000)
    session.set_paused(true)

    var result: Dictionary = session.continue_for_time(0.025)
    assert_true(result.ok)
    assert_eq(session.frame_index, 25)
    assert_almost_eq(session.simulation_time_seconds, 0.025, 0.000001)

    var invalid: Dictionary = session.continue_for_time(0.0005)
    assert_false(invalid.ok)
    assert_string_contains(invalid.error, "whole simulation frames")


func test_reset_restores_the_initial_clock_state() -> void:
    var session := AirSimSession.new(240)
    session.set_paused(true)
    session.continue_for_frames(10)
    session.reset()

    assert_eq(session.frame_index, 0)
    assert_almost_eq(session.simulation_time_seconds, 0.0, 0.000001)
    assert_false(session.is_paused())
