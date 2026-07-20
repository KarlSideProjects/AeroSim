extends GutTest


func test_quality_profile_accepts_each_render_scale_tick() -> void:
    const path := "res://common/flight/quality_profile.gd"
    assert_true(ResourceLoader.exists(path))
    if not ResourceLoader.exists(path):
        return
    var quality = load(path)
    for tick in range(11):
        var result: Dictionary = quality.validate_profile({
            "schema_version": 1,
            "render_scale": 0.50 + 0.05 * tick,
        })
        assert_true(result.ok, result.error)
        assert_eq(result.profile.render_scale, 0.50 + 0.05 * tick)


func test_quality_profile_rejects_off_step_values() -> void:
    const path := "res://common/flight/quality_profile.gd"
    assert_true(ResourceLoader.exists(path))
    if not ResourceLoader.exists(path):
        return
    var result: Dictionary = load(path).validate_profile({"schema_version": 1, "render_scale": 0.51})
    assert_false(result.ok)
    assert_string_contains(result.error, "0.05")


func test_quality_profile_requires_an_exact_schema_version() -> void:
    const path := "res://common/flight/quality_profile.gd"
    var quality = load(path)
    var near_version: Dictionary = quality.validate_profile({"schema_version": 1.000001, "render_scale": 0.75})
    assert_false(near_version.ok)
    var exact_float: Dictionary = quality.validate_profile({"schema_version": 1.0, "render_scale": 0.75})
    assert_true(exact_float.ok, exact_float.error)
