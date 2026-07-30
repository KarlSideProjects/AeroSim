extends GutTest

const HardwareConfig = preload("res://common/flight/hardware_config.gd")

var loader := HardwareConfig.new()


class FakeHardwareNative extends RefCounted:
    var a5 := {}
    var altitude_hold_noise_deadband_m := -1.0
    var config_hash_calls := 0
    var hash_applied_after_a5 := false
    var mass_kg := -1.0
    var power_model: Array = []
    var per_motor_model := {}

    func set_hardware_mass_kg(value: float) -> bool:
        mass_kg = value
        return true
    func set_hardware_power_model(a: float, b: float, c: float, d: float, e: float, f: float, g: float) -> bool:
        power_model = [a, b, c, d, e, f, g]
        return true
    func set_hardware_per_motor_model(value: Dictionary) -> bool:
        per_motor_model = value.duplicate(true)
        return true
    func set_hardware_telemetry_model(_a: float, _b: float) -> bool: return true
    func set_hardware_altitude_hold_noise_deadband(value: float) -> bool:
        altitude_hold_noise_deadband_m = value
        return true
    func set_body_drag_model(_enabled: bool, _a: float, _b: float, _c: float, _d: float, _e: float, _f: float, _g: float, _h: float, _i: float, _density: float) -> bool: return true
    func set_a3_drag_model(_enabled: bool, _x: float, _y: float, _z: float) -> bool: return true
    func set_a6_propwash_model(_enabled: bool, _a: float, _b: float, _c: float) -> bool: return true
    func a6_propwash_configuration() -> Dictionary: return {}
    func set_a5_downwash_model(enabled: bool, radius: float, coeff_1: float, coeff_2: float, coeff_3: float) -> bool:
        a5 = {"enabled": enabled, "prop_radius_m": radius, "coeff_1": coeff_1, "coeff_2": coeff_2, "coeff_3": coeff_3}
        return true
    func replay_vehicle_config_manifest() -> Dictionary: return {"complete": true}
    func replay_manifest_hash(_json: String) -> String: return "canonical-config-hash"
    func set_config_hash(_hash: String) -> bool:
        config_hash_calls += 1
        hash_applied_after_a5 = not a5.is_empty()
        return true


class FakeHardwareRuntime extends RefCounted:
    var native := FakeHardwareNative.new()


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


func test_derives_the_named_px4_iris_allocation_contract() -> void:
    var iris: Dictionary = loader.load_preset("res://config/drones/px4_iris.json")
    assert_true(loader.last_ok, loader.last_error)
    var power_model := loader.derive_power_model(iris)
    var per_motor := loader.derive_per_motor_model(iris, power_model)

    assert_true(per_motor.ok, String(per_motor.get("error", "")))
    assert_eq(per_motor.spin_direction, [-1.0, 1.0, 1.0, -1.0])
    assert_almost_eq(per_motor.position_frd[0].x, -0.1515, 0.000001)
    assert_almost_eq(per_motor.position_frd[1].y, 0.2450, 0.000001)
    assert_almost_eq(per_motor.yaw_torque_per_newton, 0.05, 0.000001)
    assert_almost_eq(iris.aircraft.mass_kg, 1.5, 0.000001)
    assert_almost_eq(iris.aircraft.inertia_kg_m2.z, 0.055225, 0.000001)


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


func test_default_airframe_applies_configured_a5_model_to_runtime() -> void:
    var runtime := FakeHardwareRuntime.new()

    assert_true(loader.apply_to_runtime(runtime, "res://config/drones/5_inch_6s.json"))
    assert_true(bool(runtime.native.a5.enabled))
    assert_almost_eq(float(runtime.native.a5.prop_radius_m), 0.0231348, 0.0000001)
    assert_almost_eq(float(runtime.native.a5.coeff_1), 2267.18, 0.000001)
    assert_eq(runtime.native.config_hash_calls, 1)
    assert_true(runtime.native.hash_applied_after_a5)
    assert_eq(runtime.native.altitude_hold_noise_deadband_m, HardwareConfig.FACTORY_DEFAULT.sensors.barometer_noise_m)


func test_race_airframe_applies_configured_a5_model_to_runtime() -> void:
    var runtime := FakeHardwareRuntime.new()

    assert_true(loader.apply_to_runtime(runtime, "res://config/drones/5_inch_6s_race.json"))
    assert_true(bool(runtime.native.a5.enabled))
    assert_almost_eq(float(runtime.native.a5.prop_radius_m), 0.0231348, 0.0000001)
    assert_almost_eq(float(runtime.native.a5.coeff_1), 2267.18, 0.000001)


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


func test_schema_accepts_the_shipped_geometry_package() -> void:
    assert_eq(loader.validate_config(HardwareConfig.FACTORY_DEFAULT.duplicate(true)), "")

    var freestyle: Dictionary = loader.load_preset("res://config/drones/5_inch_6s.json")
    assert_true(loader.last_ok, loader.last_error)
    assert_eq(String(freestyle.geometry.identity.airframe_class), "quad_x_5_inch_freestyle")
    var race: Dictionary = loader.load_preset("res://config/drones/5_inch_6s_race.json")
    assert_true(loader.last_ok, loader.last_error)
    assert_ne(String(race.geometry.identity.designation), String(freestyle.geometry.identity.designation))


func test_schema_rejects_incomplete_geometry() -> void:
    var missing_section: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    missing_section.erase("geometry")
    assert_true(loader.validate_config(missing_section).contains("geometry"))

    var missing_identity: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    missing_identity.geometry.identity.designation = ""
    assert_true(loader.validate_config(missing_identity).contains("geometry.identity.designation"))

    var out_of_range: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    out_of_range.geometry.body.arm_thickness_m = 0.0
    assert_true(loader.validate_config(out_of_range).contains("geometry.body.arm_thickness_m"))

    var bad_angle: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    bad_angle.geometry.propeller.blade_root_twist_deg = 95.0
    assert_true(loader.validate_config(bad_angle).contains("blade_root_twist_deg"))


func test_schema_rejects_unprovable_geometry_provenance() -> void:
    var unknown_evidence: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    unknown_evidence.geometry.provenance.dimensional_evidence.evidence_class = "vibes"
    assert_true(loader.validate_config(unknown_evidence).contains("evidence_class"))

    var unknown_disposition: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    unknown_disposition.geometry.provenance.redistribution = "maybe"
    assert_true(loader.validate_config(unknown_disposition).contains("redistribution"))

    var missing_attribution: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    missing_attribution.geometry.provenance.license.attribution = ""
    assert_true(loader.validate_config(missing_attribution).contains("attribution"))

    var short_hash: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    short_hash.geometry.provenance.assets[0].sha256 = "abc"
    assert_true(loader.validate_config(short_hash).contains("sha256"))

    var no_assets: Dictionary = HardwareConfig.FACTORY_DEFAULT.duplicate(true)
    no_assets.geometry.provenance.assets = []
    assert_true(loader.validate_config(no_assets).contains("assets"))


func test_geometry_does_not_reach_the_physics_runtime() -> void:
    var runtime := FakeHardwareRuntime.new()

    assert_true(loader.apply_to_runtime(runtime, "res://config/drones/5_inch_6s.json"))

    var visual_only := FakeHardwareRuntime.new()
    loader.current.geometry.body.canopy_height_m = 0.1
    loader.current.geometry.propeller.blade_max_chord_m = 0.02
    loader.current.geometry.identity.designation = "different shell"
    assert_true(loader._apply_current_to_runtime(visual_only, "res://config/drones/5_inch_6s.json"))

    assert_eq(visual_only.native.a5, runtime.native.a5)
    assert_eq(visual_only.native.mass_kg, runtime.native.mass_kg)
    assert_eq(visual_only.native.power_model, runtime.native.power_model)
    assert_eq(visual_only.native.per_motor_model, runtime.native.per_motor_model)
    assert_eq(visual_only.native.altitude_hold_noise_deadband_m, runtime.native.altitude_hold_noise_deadband_m)
