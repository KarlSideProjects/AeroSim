extends GutTest

const DemoFlightRoute = preload("res://common/flight/demo_flight_route.gd")


func test_route_starts_with_a_three_second_hover_then_visits_every_recording_phase() -> void:
    var route := DemoFlightRoute.new()
    var spawn := Vector3(0.0, 0.6, -24.0)
    route.start(spawn)

    var phases: Array[String] = []
    for second in range(61):
        var state: Dictionary = route.advance(1.0 if second > 0 else 0.0, Vector3(0.0, 3.0, -24.0), Vector3.ZERO, 0.0)
        var phase := String(state.phase)
        if phases.is_empty() or phases.back() != phase:
            phases.append(phase)

    assert_eq(phases, ["hover", "low_pass", "orbit", "climb", "return", "land", "complete"])


func test_route_stays_bounded_and_finishes_at_spawn() -> void:
    var route := DemoFlightRoute.new()
    var spawn := Vector3(0.0, 0.6, -24.0)
    route.start(spawn)

    var terminal: Dictionary = {}
    for second in range(61):
        terminal = route.advance(1.0 if second > 0 else 0.0, spawn, Vector3.ZERO, 0.0)
        assert_true(terminal.target_position.is_finite())
        assert_lte(absf(float(terminal.target_speed_mps)), 6.0)
        assert_lte(absf(float(terminal.yaw_rate_dps)), 120.0)

    assert_true(bool(terminal.complete))
    assert_eq(terminal.target_position, spawn)


func test_cancel_makes_the_route_inactive_immediately() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3(0.0, 0.6, -24.0))

    route.cancel()

    assert_false(bool(route.snapshot().active))
