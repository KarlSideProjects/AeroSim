extends GutTest

const TimeTrial = preload("res://common/flight/time_trial.gd")


func test_checkpoints_must_be_reached_in_order_before_finish() -> void:
    var trial := TimeTrial.new()
    trial.configure([Vector3(10, 0, 0), Vector3(20, 0, 0)], Vector3(30, 0, 0), 1.0)
    trial.start()

    trial.advance(Vector3(10, 0, 0), 0.5)
    assert_eq(trial.next_checkpoint_index, 1)
    assert_false(trial.finished)
    assert_almost_eq(trial.elapsed_seconds, 0.5, 0.000001)

    trial.advance(Vector3(20, 0, 0), 0.25)
    trial.advance(Vector3(30, 0, 0), 0.25)
    assert_true(trial.finished)
    assert_almost_eq(trial.elapsed_seconds, 1.0, 0.000001)


func test_skipping_a_checkpoint_does_not_finish_trial() -> void:
    var trial := TimeTrial.new()
    trial.configure([Vector3(10, 0, 0), Vector3(20, 0, 0)], Vector3(30, 0, 0), 1.0)
    trial.start()

    trial.advance(Vector3(30, 0, 0), 1.0)

    assert_eq(trial.next_checkpoint_index, 0)
    assert_false(trial.finished)


func test_reset_starts_a_new_trial_from_zero_time() -> void:
    var trial := TimeTrial.new()
    trial.configure([Vector3(10, 0, 0)], Vector3(20, 0, 0), 1.0)
    trial.start()
    trial.advance(Vector3(10, 0, 0), 2.0)
    trial.reset()

    assert_false(trial.active)
    assert_eq(trial.next_checkpoint_index, 0)
    assert_false(trial.finished)
    assert_almost_eq(trial.elapsed_seconds, 0.0, 0.000001)

    trial.start()
    assert_true(trial.active)
