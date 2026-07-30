extends GutTest

const TerrainRangeWindProfile = preload("res://common/maps/terrain_range_wind_profile.gd")
const TerrainRangeVisualWind = preload("res://common/maps/terrain_range_visual_wind.gd")


class FakeNative:
    extends RefCounted

    var steady_wind := Vector3.ZERO
    var turbulence := Vector3.ZERO

    func wind_configuration() -> Dictionary:
        return {"steady_wind": steady_wind, "shear_enabled": false}

    func sample_wind(_time_seconds: float, _x: float, _y: float, _z: float) -> Vector3:
        return steady_wind + turbulence


func test_map_presets_use_exact_northwest_to_southeast_steady_wind_speeds() -> void:
    var direction := Vector3(-1.0, 0.0, 1.0).normalized()
    for preset in ["calm", "light", "moderate", "severe"]:
        var wind := TerrainRangeWindProfile.steady_wind_for_preset(preset)
        assert_almost_eq(wind.length(), TerrainRangeWindProfile.speed_for_preset(preset), 0.000001)
        if preset == "calm":
            assert_eq(wind, Vector3.ZERO)
        else:
            assert_almost_eq(wind.dot(direction), wind.length(), 0.000001)


func test_controller_snapshot_is_finite_bounded_smooth_and_frozen_when_inactive() -> void:
    var controller := TerrainRangeVisualWind.new()
    var native := FakeNative.new()
    controller.sample_position = Vector3(480.0, 79.7, -740.0)

    controller.advance(native, 0.0, false)
    assert_eq(float(controller.snapshot().accepted_simulation_time_seconds), -1.0)

    controller.advance(native, 0.0, true)
    native.steady_wind = TerrainRangeWindProfile.steady_wind_for_preset("light")
    native.turbulence = Vector3(9.0, 0.0, -9.0)
    controller.advance(native, 0.1, true)
    var gusty := controller.snapshot()
    var prevailing: Vector2 = Vector2(native.steady_wind.x, native.steady_wind.z)
    var target: Vector2 = gusty.target_horizontal_wind
    assert_lte((target - prevailing).length(), prevailing.length() * 0.25 + 0.000001)
    assert_lt(gusty.smoothed_horizontal_wind.length(), target.length())

    for frame in 20:
        controller.advance(native, 0.2 + float(frame) * 0.1, true)
    assert_almost_eq(controller.snapshot().smoothed_horizontal_wind.length(), controller.snapshot().target_horizontal_wind.length(), 0.35)
    var frozen := controller.snapshot()
    controller.advance(native, 2.3, false)
    assert_eq(controller.snapshot(), frozen)

    var calm_controller := TerrainRangeVisualWind.new()
    native.steady_wind = Vector3.ZERO
    native.turbulence = Vector3(INF, 0.0, INF)
    calm_controller.advance(native, 2.4, true)
    var calm := calm_controller.snapshot()
    assert_eq(calm.target_horizontal_wind, Vector2.ZERO)
    assert_true(calm.target_horizontal_wind.is_finite())
    controller.free()
    calm_controller.free()


func test_clock_regression_restarts_phase_without_backward_interpolation() -> void:
    var controller := TerrainRangeVisualWind.new()
    var native := FakeNative.new()
    native.steady_wind = TerrainRangeWindProfile.steady_wind_for_preset("moderate")
    controller.advance(native, 1.0, true)
    controller.advance(native, 1.5, true)
    assert_gt(float(controller.snapshot().phase), 0.0)

    controller.advance(native, 0.25, true)
    var reset := controller.snapshot()
    assert_eq(float(reset.phase), 0.0)
    assert_eq(float(reset.accepted_simulation_time_seconds), 0.25)
    assert_true((reset.smoothed_horizontal_wind as Vector2).is_finite())
    controller.free()
