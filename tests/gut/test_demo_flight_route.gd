extends GutTest

const DemoFlightRoute = preload("res://common/flight/demo_flight_route.gd")


func test_route_advances_only_by_simulation_delta() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3.ZERO)

    route.advance(2.5, Vector3.ZERO, Vector3.ZERO, 0.0)
    assert_eq(route.snapshot().phase, "hover")
    route.advance(0.6, Vector3.ZERO, Vector3.ZERO, 0.0)
    assert_eq(route.snapshot().phase, "low_pass")


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


func test_route_keeps_low_pass_orbit_and_climb_targets_reachable_at_demo_speed() -> void:
    var route := DemoFlightRoute.new()
    var spawn := Vector3.ZERO
    route.start(spawn)

    var low_pass: Dictionary = route.advance(14.9, spawn, Vector3.ZERO, 0.0)
    assert_eq(low_pass.phase, "low_pass")
    assert_lte(Vector2(low_pass.target_position.x, low_pass.target_position.z).length(), 10.0)

    var orbit: Dictionary = route.advance(7.1, spawn, Vector3.ZERO, 0.0)
    assert_eq(orbit.phase, "orbit")
    assert_lte(Vector2(orbit.target_position.x, orbit.target_position.z).length(), 15.0)
    assert_gt(Vector2(orbit.target_position.x, orbit.target_position.z).distance_to(Vector2(low_pass.target_position.x, low_pass.target_position.z)), 0.5)

    var climb: Dictionary = route.advance(15.8, spawn, Vector3.ZERO, 0.0)
    assert_eq(climb.phase, "climb")
    assert_lte(climb.target_position.y, 7.0)
    assert_gt(climb.target_position.y, low_pass.target_position.y + 2.0)


func test_cancel_makes_the_route_inactive_immediately() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3(0.0, 0.6, -24.0))

    route.cancel()

    assert_false(bool(route.snapshot().active))
