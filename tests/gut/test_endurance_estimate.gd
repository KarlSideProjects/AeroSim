extends GutTest

const EnduranceEstimate = preload("res://common/flight/endurance_estimate.gd")


func test_estimate_counts_only_armed_simulation_time() -> void:
    var estimate := EnduranceEstimate.new()
    estimate.configure(600.0)

    assert_eq(estimate.update(1_000_000, false).state, "ready")
    assert_eq(estimate.update(2_000_000, true).remaining_seconds, 600.0)
    assert_eq(estimate.update(32_000_000, true).remaining_seconds, 570.0)
    assert_eq(estimate.update(42_000_000, false).remaining_seconds, 560.0)
    assert_eq(estimate.update(72_000_000, false).remaining_seconds, 560.0)
    assert_eq(estimate.update(82_000_000, true).remaining_seconds, 560.0)
    assert_eq(estimate.update(92_000_000, true).remaining_seconds, 550.0)


func test_estimate_resets_for_new_hardware_baseline() -> void:
    var estimate := EnduranceEstimate.new()
    estimate.configure(120.0)
    estimate.update(0, true)
    assert_eq(estimate.update(30_000_000, true).remaining_seconds, 90.0)

    estimate.configure(300.0)
    var reset := estimate.update(31_000_000, true)
    assert_eq(reset.total_seconds, 300.0)
    assert_eq(reset.remaining_seconds, 300.0)
    assert_eq(reset.ratio, 1.0)


func test_estimate_marks_missing_or_expired_duration_honestly() -> void:
    var estimate := EnduranceEstimate.new()
    assert_eq(estimate.update(0, true).state, "unavailable")

    estimate.configure(10.0)
    estimate.update(0, true)
    var expired := estimate.update(11_000_000, true)
    assert_eq(expired.state, "expired")
    assert_eq(expired.remaining_seconds, 0.0)
    assert_eq(expired.ratio, 0.0)
