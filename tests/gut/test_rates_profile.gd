extends GutTest

const RatesProfile = preload("res://common/flight/rates_profile.gd")


func test_default_profile_matches_existing_acro_configuration() -> void:
    assert_eq(
        RatesProfile.default_profile(),
        {
            "schema_version": 1,
            "rc_rate": 1.0,
            "super_rate": 13.0 / 18.0,
            "expo": 0.0,
        }
    )


func test_profile_validation_rejects_unknown_missing_nonfinite_and_out_of_range_values() -> void:
    var profile := RatesProfile.default_profile()

    var unknown := profile.duplicate(true)
    unknown["future"] = true
    assert_false(RatesProfile.validate_profile(unknown).ok)

    var missing := profile.duplicate(true)
    missing.erase("expo")
    assert_false(RatesProfile.validate_profile(missing).ok)

    var nonfinite := profile.duplicate(true)
    nonfinite["rc_rate"] = NAN
    assert_false(RatesProfile.validate_profile(nonfinite).ok)

    var out_of_range := profile.duplicate(true)
    out_of_range["super_rate"] = 1.1
    assert_false(RatesProfile.validate_profile(out_of_range).ok)

    var nonintegral_schema := profile.duplicate(true)
    nonintegral_schema["schema_version"] = 1.5
    assert_false(RatesProfile.validate_profile(nonintegral_schema).ok)


func test_json_round_trip_and_current_imported_diff_are_deterministic() -> void:
    var current: Dictionary = RatesProfile.default_profile()
    var imported: Dictionary = current.duplicate(true)
    imported["rc_rate"] = 1.15
    imported["expo"] = 0.25

    var encoded: String = RatesProfile.to_json(imported)
    var decoded: Dictionary = RatesProfile.from_json(encoded)
    assert_true(decoded.ok, decoded.error)
    assert_eq(decoded.profile.schema_version, imported.schema_version)
    assert_almost_eq(decoded.profile.rc_rate, imported.rc_rate, 0.000001)
    assert_almost_eq(decoded.profile.super_rate, imported.super_rate, 0.000001)
    assert_almost_eq(decoded.profile.expo, imported.expo, 0.000001)
    assert_eq(
        RatesProfile.diff(current, decoded.profile),
        [
            {"key": "rc_rate", "current": 1.0, "imported": 1.15},
            {"key": "expo", "current": 0.0, "imported": 0.25},
        ]
    )
