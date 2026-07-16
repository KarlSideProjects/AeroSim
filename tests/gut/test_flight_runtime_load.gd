extends GutTest

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const SettingsStoreScript = preload("res://common/flight/settings_store.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")

var rates_test_path := "user://aerosim-rates-runtime-test.json"


func after_each() -> void:
    DirAccess.remove_absolute(rates_test_path)
    DirAccess.remove_absolute("%s.tmp" % rates_test_path)


class FakeNative:
    extends RefCounted

    var disarmed := false

    func disarm_flight_control() -> void:
        disarmed = true


class FakeDeviceState:
    extends GamepadDeviceState.DeviceState

    func is_joy_known(device_id: int) -> bool:
        return device_id == 7

    func connected_joypads() -> Array[int]:
        return [7]

    func joy_name(_device_id: int) -> String:
        return "Xbox Controller"


func test_production_flight_runtime_script_loads_with_airsim_rpc_dependencies() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")

    assert_not_null(runtime_script)


func test_rates_save_does_not_overwrite_settings_when_load_recovers() -> void:
    var malformed := FileAccess.open(rates_test_path, FileAccess.WRITE)
    malformed.store_string("{not-json")
    malformed.close()

    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    runtime.settings_store = SettingsStoreScript.new(rates_test_path)

    var result: Dictionary = runtime._save_rates_profile(RatesProfile.default_profile())

    assert_false(result.ok)
    assert_string_contains(result.error, "unavailable")
    runtime.free()


func test_controller_disconnect_latches_disarm_freeze_and_blocks_keyboard_resume() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var fake_native := FakeNative.new()
    runtime.native = fake_native
    runtime.screen = "flight"
    runtime.takeoff_requested = true
    runtime.session_gamepad_device_id = 7
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    runtime.handle_controller_connection_changed(7, false)

    assert_true(runtime.controller_safety_latched)
    assert_false(runtime.takeoff_requested)
    assert_true(runtime.paused)
    assert_eq(runtime.screen, "controller_disconnected")
    assert_null(runtime.session_gamepad_profile)
    assert_eq(runtime.session_gamepad_device_id, -1)
    assert_true(fake_native.disarmed)

    runtime.arm_and_takeoff()
    assert_true(runtime.controller_safety_latched)
    assert_false(runtime.takeoff_requested)
    runtime.respawn()
    assert_true(runtime.controller_safety_latched)
    assert_false(runtime.takeoff_requested)
    assert_false(runtime._airsim_arm_disarm(true, "").ok)
    assert_false(runtime._airsim_command("takeoff", [], "").ok)
    runtime.free()


func test_controller_reconnect_restores_profile_but_not_authority() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    runtime.native = FakeNative.new()
    runtime.gamepad_device_state = FakeDeviceState.new()
    runtime.persisted_gamepad_profile = InputProfiles.GamepadProfile.new()
    runtime.screen = "flight"
    runtime.takeoff_requested = true
    runtime.session_gamepad_device_id = 7
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    runtime.handle_controller_connection_changed(7, false)
    runtime.handle_controller_connection_changed(7, true)

    assert_true(runtime.controller_safety_latched)
    assert_true(runtime.controller_reconnected)
    assert_true(runtime.paused)
    assert_false(runtime.takeoff_requested)
    assert_eq(runtime.screen, "preflight")
    assert_not_null(runtime.session_gamepad_profile)
    assert_eq(runtime.session_gamepad_device_id, 7)
    runtime.session_gamepad_profile.throttle = 0.8
    assert_eq(runtime.persisted_gamepad_profile.throttle, 0.0)
    runtime.arm_and_takeoff()
    assert_true(runtime.controller_safety_latched)
    runtime.free()
