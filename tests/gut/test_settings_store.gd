extends GutTest

const SettingsStoreScript = preload("res://common/flight/settings_store.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")

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
    profile.throttle = 0.8
    profile.sticky_throttle = true

    var persisted: Dictionary = profile.to_persisted_dict()

    assert_eq(persisted["profile_schema_version"], InputProfiles.GamepadProfile.SCHEMA_VERSION)
    assert_false(persisted.has("device_id"))
    assert_false(persisted.has("throttle"))
    assert_false(persisted.has("arm_pressed"))
    assert_false(persisted.has("mode_pressed"))
    assert_false(persisted.has("sticky_throttle"))


func test_valid_profile_round_trips_without_runtime_state() -> void:
    var profile := InputProfiles.GamepadProfile.new()
    var restored = InputProfiles.GamepadProfile.from_persisted_dict(profile.to_persisted_dict())

    assert_not_null(restored)
    assert_eq(restored.axis_for_role, profile.axis_for_role)
    assert_eq(restored.reversed_for_role, profile.reversed_for_role)
    assert_eq(restored.arm_button, profile.arm_button)
    assert_eq(restored.mode_button, profile.mode_button)
    assert_eq(restored.throttle, 0.0)
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
