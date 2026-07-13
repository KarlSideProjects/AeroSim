extends GutTest

const InputProfiles = preload("res://common/flight/input_profiles.gd")


class FakeDeviceState:
    extends RefCounted

    var known_device_ids := {}

    func _init(device_ids: Array) -> void:
        for device_id in device_ids:
            known_device_ids[device_id] = true

    func is_joy_known(device_id: int) -> bool:
        return known_device_ids.has(device_id)


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


func test_unknown_xbox_device_is_rejected() -> void:
    var profile = InputProfiles.GamepadProfile.xbox_default(8, FakeDeviceState.new([7]))

    assert_null(profile, "Unknown SDL devices must not be assigned an unsafe guessed control mapping.")


func test_throttle_stays_sticky_inside_the_deadzone() -> void:
    var profile := InputProfiles.GamepadProfile.new()
    profile.apply_throttle_axis(0.75)
    profile.apply_throttle_axis(profile.RAW_AXIS_DEADZONE)

    assert_almost_eq(
        profile.throttle,
        0.75,
        0.000001,
        "Deadzone noise must not make an armed aircraft's sticky throttle jump."
    )
