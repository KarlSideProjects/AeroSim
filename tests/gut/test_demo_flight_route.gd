extends GutTest

const DemoFlightRoute = preload("res://common/flight/demo_flight_route.gd")


func test_route_advances_only_by_simulation_delta() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3.ZERO)

    route.advance(2.5, Vector3.ZERO, Vector3.ZERO, 0.0)
    assert_eq(route.snapshot().phase, "hover")
    route.advance(2.6, Vector3.ZERO, Vector3.ZERO, 0.0)
    assert_eq(route.snapshot().phase, "low_pass")


func test_route_starts_with_a_five_second_hover_then_visits_every_recording_phase() -> void:
    var route := DemoFlightRoute.new()
    var spawn := Vector3(0.0, 0.6, -24.0)
    route.start(spawn)

    var phases: Array[String] = []
    for second in range(181):
        var state: Dictionary = route.advance(1.0 if second > 0 else 0.0, Vector3(0.0, 3.0, -24.0), Vector3.ZERO, 0.0)
        var phase := String(state.phase)
        if phases.is_empty() or phases.back() != phase:
            phases.append(phase)

    assert_eq(phases, ["hover", "low_pass", "orbit", "climb", "return", "land", "complete"])


func test_route_keeps_the_approved_three_minute_phase_boundaries() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3.ZERO)

    assert_eq(route.advance(5.0, Vector3.ZERO, Vector3.ZERO, 0.0).phase, "low_pass")
    assert_eq(route.advance(20.0, Vector3.ZERO, Vector3.ZERO, 0.0).phase, "orbit")
    assert_eq(route.advance(85.0, Vector3.ZERO, Vector3.ZERO, 0.0).phase, "climb")
    assert_eq(route.advance(15.0, Vector3.ZERO, Vector3.ZERO, 0.0).phase, "return")
    assert_eq(route.advance(45.0, Vector3.ZERO, Vector3.ZERO, 0.0).phase, "land")
    assert_true(bool(route.advance(10.0, Vector3.ZERO, Vector3.ZERO, 0.0).complete))


func test_route_stays_bounded_and_finishes_at_spawn() -> void:
    var route := DemoFlightRoute.new()
    var spawn := Vector3(0.0, 0.6, -24.0)
    route.start(spawn)

    var terminal: Dictionary = {}
    for second in range(181):
        terminal = route.advance(1.0 if second > 0 else 0.0, spawn, Vector3.ZERO, 0.0)
        assert_true(terminal.target_position.is_finite())
        assert_lte(absf(float(terminal.target_speed_mps)), 6.0)
        assert_lte(absf(float(terminal.yaw_rate_dps)), 120.0)

    assert_true(bool(terminal.complete))
    assert_eq(terminal.target_position, spawn)


func test_route_orbits_the_control_tower_with_clearance_and_a_high_pass() -> void:
    var route := DemoFlightRoute.new()
    var spawn := Vector3.ZERO
    route.start(spawn)
    var control_tower := Vector2(36.0, 46.0)

    var low_pass: Dictionary = route.advance(24.9, spawn, Vector3.ZERO, 0.0)
    assert_eq(low_pass.phase, "low_pass")
    var low_pass_horizontal := Vector2(low_pass.target_position.x, low_pass.target_position.z)
    assert_gte(low_pass_horizontal.distance_to(control_tower), 45.0)
    assert_lte(low_pass_horizontal.distance_to(control_tower), 50.0)

    var orbit: Dictionary = route.advance(14.0, spawn, Vector3.ZERO, 0.0)
    assert_eq(orbit.phase, "orbit")
    var orbit_horizontal := Vector2(orbit.target_position.x, orbit.target_position.z)
    assert_gte(orbit_horizontal.distance_to(control_tower), 20.0)
    assert_lte(orbit_horizontal.distance_to(control_tower), 25.0)
    assert_lte(orbit_horizontal.length(), 80.0)

    var climb: Dictionary = route.advance(85.1, spawn, Vector3.ZERO, 0.0)
    assert_eq(climb.phase, "climb")
    assert_gt(climb.target_position.y, 23.0)
    assert_lte(climb.target_position.y, 26.0)
    assert_lte(Vector2(climb.target_position.x, climb.target_position.z).length(), 145.0)


func test_route_targets_keep_clear_of_the_control_tower_and_workshop() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3.ZERO)
    var control_tower := Vector2(36.0, 46.0)
    var workshop := Vector2(40.0, 18.0)

    for second in range(181):
        var state: Dictionary = route.advance(1.0 if second > 0 else 0.0, Vector3.ZERO, Vector3.ZERO, 0.0)
        var target := Vector2(state.target_position.x, state.target_position.z)
        assert_gte(target.distance_to(control_tower), 14.0)
        assert_gte(target.distance_to(workshop), 12.0)


func test_orbit_target_never_outpaces_the_drone_cruise_speed() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3.ZERO)
    route.advance(DemoFlightRoute.LOW_PASS_END_SECONDS, Vector3.ZERO, Vector3.ZERO, 0.0)
    var prior: Dictionary = route.snapshot()
    var step := 1.0 / 60.0

    for _tick in range(int((DemoFlightRoute.ORBIT_END_SECONDS - DemoFlightRoute.LOW_PASS_END_SECONDS) / step) - 1):
        var current: Dictionary = route.advance(step, Vector3.ZERO, Vector3.ZERO, 0.0)
        assert_eq(current.phase, "orbit")
        assert_lte(prior.target_position.distance_to(current.target_position), DemoFlightRoute.CRUISE_SPEED_MPS * step + 0.0001)
        prior = current


func test_cancel_makes_the_route_inactive_immediately() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3(0.0, 0.6, -24.0))

    route.cancel()

    assert_false(bool(route.snapshot().active))
