extends GutTest

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")


class FakeDeviceState:
    extends RefCounted

    var known_device_ids := {}

    func _init(device_ids: Array) -> void:
        for device_id in device_ids:
            known_device_ids[device_id] = true

    func is_joy_known(device_id: int) -> bool:
        return known_device_ids.has(device_id)

    func joy_name(_device_id: int) -> String:
        return "Xbox Test Controller"


func test_no_controller_status_names_the_keyboard_fallback() -> void:
    assert_eq(
        InputProfiles.fallback_status([]),
        "No controller detected; KeyboardProfile fallback active (non-sim control)",
        "Pilots must be told that keyboard fallback is active and is not simulator-grade control."
    )


func test_known_xbox_device_gets_the_fixed_profile() -> void:
    var profile = InputProfiles.GamepadProfile.xbox_default(7, FakeDeviceState.new([7]))

    assert_not_null(profile, "Known SDL devices must receive the supported Xbox control profile.")
    assert_eq(
        profile.profile_schema_version,
        InputProfiles.GamepadProfile.SCHEMA_VERSION,
        "Known devices must use the locked profile schema so control mappings stay stable."
    )


func test_xbox_profile_uses_canonical_mode_two_axes() -> void:
    var profile = InputProfiles.GamepadProfile.xbox_default(7, FakeDeviceState.new([7]))

    assert_eq(profile.axis_for_role, {
        "yaw": JOY_AXIS_LEFT_X,
        "throttle": JOY_AXIS_LEFT_Y,
        "roll": JOY_AXIS_RIGHT_X,
        "pitch": JOY_AXIS_RIGHT_Y,
    })
    assert_eq(profile.reversed_for_role, {
        "yaw": false,
        "throttle": true,
        "roll": false,
        "pitch": true,
    })


func test_prior_xbox_profile_schema_is_rejected_instead_of_silently_remapped() -> void:
    var prior_profile := {
        "profile_schema_version": 1,
        "axis_for_role": {
            "roll": JOY_AXIS_LEFT_X,
            "pitch": JOY_AXIS_LEFT_Y,
            "yaw": JOY_AXIS_RIGHT_X,
            "throttle": JOY_AXIS_RIGHT_Y,
        },
        "reversed_for_role": {
            "roll": false,
            "pitch": true,
            "yaw": false,
            "throttle": false,
        },
        "arm_button": JOY_BUTTON_A,
        "mode_button": JOY_BUTTON_Y,
        "deadzone": 0.08,
    }

    assert_false(InputProfiles.GamepadProfile.validate_persisted_dict(prior_profile).ok)


func test_mode_two_arm_safety_requires_the_left_stick_to_be_physically_down() -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(7, FakeDeviceState.new([7]))

    assert_true(profile.throttle_axis_is_low(1.0))
    assert_false(profile.throttle_axis_is_low(-1.0))


func test_mode_two_axis_curve_is_symmetric_and_softens_the_center() -> void:
    var runtime := FlightRuntime.new()
    var positive := runtime._normalize_gamepad_axis(0.5, InputProfiles.GamepadProfile.RAW_AXIS_DEADZONE)
    var negative := runtime._normalize_gamepad_axis(-0.5, InputProfiles.GamepadProfile.RAW_AXIS_DEADZONE)

    assert_almost_eq(positive, 0.42038, 0.00001)
    assert_almost_eq(negative, -0.42038, 0.00001)
    runtime.free()


func test_unknown_xbox_device_is_rejected() -> void:
    var profile = InputProfiles.GamepadProfile.xbox_default(8, FakeDeviceState.new([7]))

    assert_null(profile, "Unknown SDL devices must not be assigned an unsafe guessed control mapping.")


func test_action_contract_exposes_fixed_profile_defaults() -> void:
    var keyboard := InputProfiles.ActionContract.default_bindings("KeyboardProfile")
    var gamepad := InputProfiles.ActionContract.default_bindings("GamepadProfile")
    assert_eq(keyboard["pause"], "P")
    assert_eq(keyboard["change_spawn"], "SHIFT+R")
    assert_eq(gamepad["reset"], "X")
    assert_eq(gamepad["change_spawn"], "START+X")

    assert_eq(InputProfiles.ActionContract.glyph(keyboard, "reset"), "R")


func test_action_contract_rejects_conflicting_bindings() -> void:
    var bindings := InputProfiles.ActionContract.default_bindings("KeyboardProfile")
    bindings["mode"] = bindings["pause"]

    var result: Dictionary = InputProfiles.ActionContract.validate_bindings(bindings)

    assert_false(result.ok)
    assert_string_contains(result.error, "conflict")


func test_action_contract_matches_project_input_map() -> void:
    var result: Dictionary = InputProfiles.ActionContract.validate_input_map()

    assert_true(result.ok, result.error)
