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


func test_derives_the_preset_backed_per_motor_model() -> void:
    var power_model := loader.derive_power_model(HardwareConfig.FACTORY_DEFAULT)
    var per_motor := loader.derive_per_motor_model(HardwareConfig.FACTORY_DEFAULT, power_model)

    assert_true(per_motor.ok)
    assert_eq(per_motor.spin_direction, [1.0, -1.0, -1.0, 1.0])
    assert_eq(per_motor.position_frd.size(), 4)
    assert_almost_eq(per_motor.max_thrust_per_motor_newtons, 16.2, 0.000001)
    assert_almost_eq(per_motor.yaw_torque_per_newton, 0.1575 / 16.2, 0.000001)


func test_schema_requires_static_a3_coefficients_without_dynamic_rpm() -> void:
    var config: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)

    assert_false(config.aerodynamics.a3.enabled)
    assert_true(config.aerodynamics.a3.coefficient_kg.has("x"))
    assert_false(config.aerodynamics.a3.has("motor_rpm"))
    assert_eq(loader.validate_config(config), "")


func test_schema_requires_static_a6_propwash_calibration() -> void:
    var config: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)

    assert_false(config.aerodynamics.a6.enabled)
    assert_eq(loader.validate_config(config), "")

    config.aerodynamics.a6.minimum_transverse_rate_rad_s = -0.1
    assert_true(loader.validate_config(config).contains("minimum_transverse_rate_rad_s"))


func test_schema_rejects_invalid_a3_values() -> void:
    var negative: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    negative.aerodynamics.a3.coefficient_kg.x = -0.1
    assert_true(loader.validate_config(negative).contains("coefficient_kg.x"))

    var non_boolean: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    non_boolean.aerodynamics.a3.enabled = 1
    assert_true(loader.validate_config(non_boolean).contains("enabled"))

    var missing: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    missing.aerodynamics.a3.erase("coefficient_kg")
    assert_true(loader.validate_config(missing).contains("coefficient_kg"))
