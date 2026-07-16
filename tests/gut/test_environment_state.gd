extends GutTest

const EnvironmentState = preload("res://common/rpc/environment_state.gd")


func test_environment_state_accepts_bounded_controls_and_returns_deep_snapshot() -> void:
    var environment := EnvironmentState.new()
    autofree(environment)

    var result := environment.apply({
        "wind_preset": "moderate",
        "steady_wind": Vector3(3.0, 0.0, -2.0),
        "rain": 0.25,
        "fog": 0.4,
        "time_of_day": 18.5,
        "sun_position": Vector3(0.0, 0.7, -0.7),
    })

    assert_true(result.ok)
    assert_eq(environment.snapshot().wind_preset, "moderate")
    assert_eq(environment.snapshot().rain, 0.25)
    assert_eq(environment.revision, 1)


func test_environment_state_rejects_unknown_or_unbounded_values_without_partial_apply() -> void:
    var environment := EnvironmentState.new()
    autofree(environment)
    var before := environment.snapshot()

    var result := environment.apply({"rain": 2.0, "future": true})

    assert_false(result.ok)
    assert_string_contains(result.error, "rain")
    assert_string_contains(result.error, "future")
    assert_eq(environment.snapshot(), before)
    assert_eq(environment.revision, 0)


func test_environment_state_rejects_unknown_wind_presets_and_normalizes_sun_direction() -> void:
    var environment := EnvironmentState.new()
    autofree(environment)

    var invalid := environment.apply({"wind_preset": "hurricane"})
    assert_false(invalid.ok)
    assert_string_contains(invalid.error, "wind_preset")
    var valid := environment.apply({"sun_position": Vector3(0.0, 4.0, 0.0)})
    assert_true(valid.ok)
    assert_almost_eq(environment.snapshot().sun_position.length(), 1.0, 0.000001)


func test_environment_state_reset_reproduces_the_initial_state() -> void:
    var environment := EnvironmentState.new()
    autofree(environment)
    var initial := environment.snapshot()
    assert_true(environment.apply({"fog": 0.5, "time_of_day": 6.0}).ok)

    environment.reset()

    assert_eq(environment.snapshot(), initial)
    assert_eq(environment.revision, 2)
