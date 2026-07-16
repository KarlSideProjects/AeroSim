extends GutTest

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")


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


func test_runtime_rejects_more_than_two_named_vehicles_before_dashboard_setup() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var validation: Dictionary = runtime._validate_airsim_startup_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "DroneA": {"VehicleType": "SimpleFlight"},
            "DroneB": {"VehicleType": "SimpleFlight"},
            "DroneC": {"VehicleType": "SimpleFlight"},
        },
    })

    assert_false(validation.ok)
    assert_string_contains(validation.error, "one or two")
    runtime.free()


func test_runtime_rejects_secondary_px4_without_a_second_bridge() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var validation: Dictionary = runtime._validate_airsim_startup_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "DroneA": {"VehicleType": "SimpleFlight"},
            "DroneB": {"VehicleType": "PX4Multirotor"},
        },
    })

    assert_false(validation.ok)
    assert_string_contains(validation.error, "secondary")
    assert_string_contains(validation.error, "PX4Multirotor")
    runtime.free()


func test_single_vehicle_disables_secondary_collision_shape_and_restores_scene_ownership() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var body := RigidBody3D.new()
    body.collision_layer = 4
    body.collision_mask = 8
    var shape := CollisionShape3D.new()
    body.add_child(shape)
    runtime.add_child(body)
    runtime.secondary_drone_body = body

    runtime._set_secondary_collision_enabled(false)
    assert_eq(body.collision_layer, 0)
    assert_eq(body.collision_mask, 0)
    assert_true(shape.disabled)

    runtime._set_secondary_collision_enabled(true)
    assert_eq(body.collision_layer, 4)
    assert_eq(body.collision_mask, 8)
    assert_false(shape.disabled)
    runtime.free()


func test_set_paused_freezes_and_sleeps_secondary_until_resume() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var secondary_body := RigidBody3D.new()
    runtime.add_child(secondary_body)
    runtime.secondary_drone_body = secondary_body

    runtime.set_paused(true, false)
    assert_true(secondary_body.freeze)
    assert_true(secondary_body.sleeping)

    runtime.set_paused(false, false)
    assert_false(secondary_body.freeze)
    assert_false(secondary_body.sleeping)
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
