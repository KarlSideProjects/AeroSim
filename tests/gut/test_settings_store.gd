extends GutTest

const SettingsStoreScript = preload("res://common/flight/settings_store.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")
const LanguageProfile = preload("res://common/flight/language_profile.gd")
const CameraProfile = preload("res://common/flight/camera_profile.gd")
const OsdProfile = preload("res://common/flight/osd_profile.gd")

var test_path := "user://aerosim-settings-store-test.json"


func after_each() -> void:
    DirAccess.remove_absolute(test_path)
    DirAccess.remove_absolute("%s.tmp" % test_path)


func test_default_document_has_one_allowlisted_versioned_envelope() -> void:
    var store = SettingsStoreScript.new("user://aerosim-test-settings.json")
    var result: Dictionary = store.validate_document({
        "schema_version": 1,
        "confirmed_gamepad": null,
        "rates": null,
        "osd": null,
        "camera": null,
        "language": null,
        "quality": null
    })

    assert_true(result.ok, result.error)
    assert_eq(
        result.document.keys(),
        ["schema_version", "confirmed_gamepad", "rates", "osd", "camera", "language", "quality"]
    )


func test_settings_store_rejects_unknown_or_future_schema_without_partial_apply() -> void:
    var store = SettingsStoreScript.new("user://aerosim-test-settings.json")
    var unknown: Dictionary = store.validate_document({
        "schema_version": 1,
        "confirmed_gamepad": null,
        "rates": null,
        "osd": null,
        "camera": null,
        "language": null,
        "quality": null,
        "future": true
    })
    var future: Dictionary = store.validate_document({
        "schema_version": 2,
        "confirmed_gamepad": null,
        "rates": null,
        "osd": null,
        "camera": null,
        "language": null,
        "quality": null
    })

    assert_false(unknown.ok)
    assert_string_contains(unknown.error, "future")
    assert_false(future.ok)
    assert_string_contains(future.error, "schema_version")


func test_settings_store_validates_the_versioned_rates_slot() -> void:
    var store = SettingsStoreScript.new("user://aerosim-test-settings.json")
    var invalid := store.default_document()
    invalid["rates"] = RatesProfile.default_profile()
    invalid["rates"]["expo"] = 2.0

    var rejected: Dictionary = store.validate_document(invalid)

    assert_false(rejected.ok)
    assert_string_contains(rejected.error, "expo")

    var valid := store.default_document()
    valid["rates"] = RatesProfile.default_profile()
    var accepted: Dictionary = store.validate_document(valid)
    assert_true(accepted.ok, accepted.error)


func test_settings_store_validates_the_versioned_quality_slot() -> void:
    var store = SettingsStoreScript.new("user://aerosim-test-settings.json")
    var invalid := store.default_document()
    invalid["quality"] = {"schema_version": 1, "render_scale": 0.51}

    var rejected: Dictionary = store.validate_document(invalid)

    assert_false(rejected.ok)
    assert_string_contains(rejected.error, "0.05")

    var valid := store.default_document()
    valid["quality"] = {"schema_version": 1, "render_scale": 1.0}
    var accepted: Dictionary = store.validate_document(valid)
    assert_true(accepted.ok, accepted.error)
    assert_eq(accepted.document["quality"], {"schema_version": 1, "render_scale": 1.0})

    var unconfigured: Dictionary = store.validate_document(store.default_document())
    assert_true(unconfigured.ok, unconfigured.error)

    var missing := store.default_document()
    missing.erase("quality")
    var missing_result: Dictionary = store.validate_document(missing)
    assert_false(missing_result.ok)
    assert_string_contains(missing_result.error, "quality")


func test_settings_store_validates_camera_and_osd_slots() -> void:
    var store = SettingsStoreScript.new(test_path)
    var document := store.default_document()
    document["camera"] = CameraProfile.default_profile()
    document["osd"] = OsdProfile.default_profile()
    var accepted: Dictionary = store.validate_document(document)

    assert_true(accepted.ok, accepted.error)
    assert_eq(accepted.document["camera"], CameraProfile.default_profile())
    assert_eq(accepted.document["osd"], OsdProfile.default_profile())

    var invalid_camera := document.duplicate(true)
    invalid_camera["camera"]["fov_deg"] = 181.0
    assert_false(store.validate_document(invalid_camera).ok)

    var invalid_osd := document.duplicate(true)
    invalid_osd["osd"]["preset"] = "Telemetry"
    assert_false(store.validate_document(invalid_osd).ok)


func test_osd_presets_are_complete_and_keep_bottom_labels_out_of_center_third() -> void:
    for preset in OsdProfile.PRESETS:
        var profile: Dictionary = OsdProfile.profile_for_preset(preset)
        var validation: Dictionary = OsdProfile.validate_profile(profile)
        assert_true(validation.ok, validation.error)
        assert_eq(profile.elements.keys().size(), OsdProfile.ELEMENTS.size())
        assert_true(float(profile.positions.warnings.x) < 1.0 / 3.0)
        assert_true(float(profile.positions.reset_hint.x) >= 2.0 / 3.0)
    assert_false(OsdProfile.profile_for_preset("Minimal").elements.flight_mode)
    assert_true(OsdProfile.profile_for_preset("Race").elements.lap_checkpoint)
    assert_true(OsdProfile.profile_for_preset("Debug").elements.signal)


func test_load_migrates_only_shipped_legacy_osd_coordinates() -> void:
    var store = SettingsStoreScript.new(test_path)
    var legacy := store.default_document()
    legacy["osd"] = OsdProfile.default_profile()
    legacy["osd"]["positions"]["warnings"] = {"x": 0.03, "y": 0.78}
    legacy["osd"]["positions"]["reset_hint"] = {"x": 0.03, "y": 0.90}
    var file := FileAccess.open(test_path, FileAccess.WRITE)
    file.store_string(JSON.stringify(legacy))
    file.close()
    if OS.has_feature("linux"):
        FileAccess.set_unix_permissions(test_path, 384)

    var migrated: Dictionary = store.load_document()

    assert_true(migrated.ok, migrated.error)
    assert_eq(migrated.document.osd.positions.warnings, OsdProfile.DEFAULT_POSITIONS.warnings)
    assert_eq(migrated.document.osd.positions.reset_hint, OsdProfile.DEFAULT_POSITIONS.reset_hint)

    for custom_positions in [
        {"warnings": {"x": 0.04, "y": 0.77}, "reset_hint": {"x": 0.03, "y": 0.90}},
        {"warnings": {"x": 0.03, "y": 0.78}, "reset_hint": {"x": 0.70, "y": 0.88}},
    ]:
        var custom := legacy.duplicate(true)
        custom["osd"]["positions"].merge(custom_positions, true)
        file = FileAccess.open(test_path, FileAccess.WRITE)
        file.store_string(JSON.stringify(custom))
        file.close()
        if OS.has_feature("linux"):
            FileAccess.set_unix_permissions(test_path, 384)

        var preserved: Dictionary = store.load_document()

        assert_true(preserved.ok, preserved.error)
        assert_eq(preserved.document.osd.positions, custom.osd.positions)


func test_camera_and_osd_settings_round_trip_and_factory_reset() -> void:
    var store = SettingsStoreScript.new(test_path)
    var document := store.default_document()
    document["camera"] = CameraProfile.default_profile()
    document["camera"]["camera_angle_deg"] = 45.0
    document["osd"] = OsdProfile.profile_for_preset("Race")
    assert_true(store.save_document(document).ok)

    var loaded: Dictionary = store.load_document()
    assert_true(loaded.ok, loaded.error)
    assert_eq(loaded.document["camera"]["camera_angle_deg"], 45.0)
    assert_eq(loaded.document["osd"]["preset"], "Race")

    assert_true(store.factory_reset().ok)
    var reset: Dictionary = store.load_document()
    assert_true(reset.ok, reset.error)
    assert_eq(reset.document, store.default_document())


func test_settings_store_validates_the_versioned_language_slot() -> void:
    var store = SettingsStoreScript.new("user://aerosim-test-settings.json")
    var valid := store.default_document()
    valid["language"] = LanguageProfile.default_profile()
    var accepted: Dictionary = store.validate_document(valid)
    assert_true(accepted.ok, accepted.error)

    var invalid := store.default_document()
    invalid["language"] = {"schema_version": LanguageProfile.SCHEMA_VERSION, "locale": "fr"}
    var rejected: Dictionary = store.validate_document(invalid)
    assert_false(rejected.ok)
    assert_string_contains(rejected.error, "locale")


func test_settings_store_round_trips_a_versioned_language_profile() -> void:
    var store = SettingsStoreScript.new(test_path)
    var document := store.default_document()
    document["language"] = LanguageProfile.default_profile()

    var saved: Dictionary = store.save_document(document)
    var loaded: Dictionary = store.load_document()

    assert_true(saved.ok, saved.error)
    assert_true(loaded.ok, loaded.error)
    assert_eq(loaded.document["language"], LanguageProfile.default_profile())


func test_settings_store_rejects_nonintegral_json_schema_version() -> void:
    var store = SettingsStoreScript.new(test_path)
    var malformed := FileAccess.open(test_path, FileAccess.WRITE)
    malformed.store_string(JSON.stringify({
        "schema_version": 1.5,
        "confirmed_gamepad": null,
        "rates": null,
        "osd": null,
        "camera": null,
        "language": null,
        "quality": null
    }))
    malformed.close()

    var recovered := store.load_document()

    assert_false(recovered.ok)
    assert_true(recovered.recovered)
    assert_true(recovered.error.contains("settings"))


func test_confirmed_profile_serialization_excludes_device_and_live_input_state() -> void:
    var profile := InputProfiles.GamepadProfile.new()
    profile.arm_pressed = true
    profile.mode_pressed = true

    var persisted: Dictionary = profile.to_persisted_dict()

    assert_eq(persisted["profile_schema_version"], InputProfiles.GamepadProfile.SCHEMA_VERSION)
    assert_false(persisted.has("device_id"))
    assert_false(persisted.has("arm_pressed"))
    assert_false(persisted.has("mode_pressed"))


func test_valid_profile_round_trips_without_runtime_state() -> void:
    var profile := InputProfiles.GamepadProfile.new()
    var restored = InputProfiles.GamepadProfile.from_persisted_dict(profile.to_persisted_dict())

    assert_not_null(restored)
    assert_eq(restored.axis_for_role, profile.axis_for_role)
    assert_eq(restored.reversed_for_role, profile.reversed_for_role)
    assert_eq(restored.arm_button, profile.arm_button)
    assert_eq(restored.mode_button, profile.mode_button)
    assert_false(restored.arm_pressed)
    assert_false(restored.mode_pressed)


func test_persisted_profile_rejects_noncanonical_mapping_and_buttons() -> void:
    var persisted := InputProfiles.GamepadProfile.new().to_persisted_dict()
    persisted["axis_for_role"]["roll"] = 99
    assert_false(InputProfiles.GamepadProfile.validate_persisted_dict(persisted).ok)
    persisted = InputProfiles.GamepadProfile.new().to_persisted_dict()
    persisted["mode_button"] = JOY_BUTTON_B
    assert_false(InputProfiles.GamepadProfile.validate_persisted_dict(persisted).ok)
    persisted = InputProfiles.GamepadProfile.new().to_persisted_dict()
    persisted["deadzone"] = 0.2
    assert_false(InputProfiles.GamepadProfile.validate_persisted_dict(persisted).ok)


func test_save_then_load_is_atomic_and_corrupt_data_recovers_complete_defaults() -> void:
    var store = SettingsStoreScript.new(test_path)
    var document := store.default_document()
    document["language"] = {"locale": "en"}

    var saved: Dictionary = store.save_document(document)
    var loaded: Dictionary = store.load_document()

    assert_true(saved.ok, saved.error)
    if OS.has_feature("linux"):
        assert_eq(FileAccess.get_unix_permissions(test_path), 384)
    assert_true(loaded.ok, loaded.error)
    assert_false(loaded.recovered)
    assert_eq(loaded.document["language"], {"locale": "en"})

    var corrupt := FileAccess.open(test_path, FileAccess.WRITE)
    corrupt.store_string("{not-json")
    corrupt.close()
    var recovered: Dictionary = store.load_document()

    assert_false(recovered.ok)
    assert_true(recovered.recovered)
    assert_eq(recovered.document, store.default_document())


func test_factory_reset_writes_complete_defaults() -> void:
    var store = SettingsStoreScript.new(test_path)
    var document := store.default_document()
    document["confirmed_gamepad"] = InputProfiles.GamepadProfile.new().to_persisted_dict()
    var initial_save := store.save_document(document)
    assert_true(initial_save.ok, initial_save.error)

    var reset := store.factory_reset()
    var loaded := store.load_document()

    assert_true(reset.ok, reset.error)
    assert_true(loaded.ok, loaded.error)
    assert_eq(loaded.document, store.default_document())


func test_invalid_save_keeps_previous_complete_document() -> void:
    var store = SettingsStoreScript.new(test_path)
    var original := store.default_document()
    original["language"] = {"locale": "en"}
    assert_true(store.save_document(original).ok)

    var invalid := original.duplicate(true)
    invalid["future"] = true
    var failed := store.save_document(invalid)
    var loaded := store.load_document()

    assert_false(failed.ok)
    assert_true(loaded.ok, loaded.error)
    assert_eq(loaded.document, original)


func test_existing_settings_with_wrong_permissions_recover_to_defaults() -> void:
    if not OS.has_feature("linux"):
        pass_test("0600 is Linux-specific")
        return
    var store = SettingsStoreScript.new(test_path)
    assert_true(store.save_document(store.default_document()).ok)
    assert_eq(FileAccess.set_unix_permissions(test_path, 420), OK)

    var recovered := store.load_document()

    assert_false(recovered.ok)
    assert_true(recovered.recovered)
    assert_string_contains(recovered.error, "0600")
