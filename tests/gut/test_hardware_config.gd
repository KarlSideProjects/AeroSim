extends GutTest

const HardwareConfig = preload("res://common/flight/hardware_config.gd")

var loader := HardwareConfig.new()


func test_prop_sample_linearly_interpolates_inside_measured_range() -> void:
    var sample := loader.prop_sample_at_rpm(HardwareConfig.FACTORY_DEFAULT, 7000.0)

    assert_true(sample.ok, "In-range RPM must produce a usable measured-table sample.")
    assert_almost_eq(
        sample.thrust_n,
        4.176,
        0.000001,
        "In-range thrust must remain linear so the physics model matches the declared interpolation contract."
    )


func test_prop_sample_does_not_extrapolate_beyond_measurements() -> void:
    var below := loader.prop_sample_at_rpm(HardwareConfig.FACTORY_DEFAULT, 3999.0)
    var above := loader.prop_sample_at_rpm(HardwareConfig.FACTORY_DEFAULT, 15001.0)

    assert_false(below.ok, "Physics must not invent propeller performance below measured RPM.")
    assert_false(above.ok, "Physics must not invent propeller performance above measured RPM.")


func test_schema_rejects_wrong_units() -> void:
    var config: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    config["units"]["mass"] = "lb"

    assert_eq(
        loader.validate_config(config),
        "units must match schema",
        "Wrong units must be rejected before they can silently corrupt physical calculations."
    )
