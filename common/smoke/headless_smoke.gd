extends SceneTree

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const CollisionProbeBodyScript = preload("res://common/flight/collision_probe_body.gd")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")

class InputProbe:
    extends Node

    var action := ""
    var pressed := false

    func _input(event: InputEvent) -> void:
        if event.is_action_pressed(action):
            pressed = true

var verified_jolt_collision_trials := 0

func _initialize() -> void:
    _run()

func _run() -> void:
    var output_path := _output_path()
    var csv_output_path := _csv_output_path()
    var requested_frames := _requested_frames()
    var requested_seconds := _requested_seconds(requested_frames)
    if not await _verify_keyboard_profile_actions():
        quit(1)
        return
    if not await _verify_gamepad_profile_actions():
        quit(1)
        return
    var input_fallback_status := _input_fallback_status()
    if not input_fallback_status.contains("KeyboardProfile") or not input_fallback_status.contains("non-sim"):
        push_error("No-controller fallback status must explicitly name KeyboardProfile and non-sim control")
        quit(1)
        return

    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        quit(1)
        return

    var probe_value: int = native.call("probe_value")

    if probe_value != 47:
        push_error("AeroSimNative.probe_value returned %d" % probe_value)
        quit(1)
        return
    if native.call("arm_flight_control", 0.25):
        push_error("AeroSimNative.arm_flight_control must reject high throttle")
        quit(1)
        return
    if native.call("flight_control_arm_reject_code") != "throttle_not_low":
        push_error("AeroSimNative must expose a high-throttle arm rejection reason")
        quit(1)
        return
    if not _verify_flight_control_public_path(native):
        quit(1)
        return
    var imu_public_verified := _verify_imu_public_path(native)
    if not imu_public_verified:
        quit(1)
        return
    var collision_public_verified := _verify_collision_public_path(native)
    if not collision_public_verified:
        quit(1)
        return
    var jolt_collision_verified := await _verify_jolt_collision_scene(native)
    if not jolt_collision_verified:
        quit(1)
        return
    if not await _verify_runtime_actions():
        quit(1)
        return

    var trajectory := PackedFloat64Array()
    native.call("reset_simulation")
    for _frame in range(requested_frames):
        await physics_frame
        var row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.0)
        trajectory.append_array(row)

    var mobile_trajectory: PackedFloat64Array = native.call("simulate_trajectory", 1.0, 120, 500, 0.0)
    var stride: int = native.call("trajectory_stride")

    if trajectory.is_empty() or mobile_trajectory.is_empty() or stride != 12:
        push_error("AeroSimNative.simulate_trajectory returned invalid data")
        quit(1)
        return

    if not _write_trajectory_csv(csv_output_path, trajectory, stride):
        quit(1)
        return

    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write smoke output: %s" % output_path)
        quit(1)
        return

    file.store_string(JSON.stringify({
        "schema_version": 1,
        "native_probe": probe_value,
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "requested_seconds": float(requested_frames) / float(Engine.physics_ticks_per_second),
        "simulated_frames": requested_frames,
        "trajectory_csv": csv_output_path,
        "trajectory_stride": stride,
        "trajectory_samples": int(trajectory.size() / stride),
        "input_fallback_status": input_fallback_status,
        "imu_public_path": imu_public_verified,
        "collision_public_path": collision_public_verified,
        "jolt_collision_handoff": jolt_collision_verified,
        "jolt_collision_trials": verified_jolt_collision_trials,
        "desktop_substep_hz": 1000,
        "desktop_substeps": int(trajectory[trajectory.size() - 1]),
        "mobile_substep_hz": 500,
        "mobile_substeps_1s": int(mobile_trajectory[mobile_trajectory.size() - 1])
    }))
    file.close()
    quit(0)

func _input_fallback_status() -> String:
    return InputProfiles.fallback_status(Input.get_connected_joypads())

func _verify_imu_public_path(native: Object) -> bool:
    for method in ["configure_imu", "imu_configuration", "flight_control_diagnostics"]:
        if not native.has_method(method):
            push_error("AeroSimNative.%s must exist for IMU public configuration and attitude-source diagnostics" % method)
            return false

    var quiet_config := {
        "noise_enabled": false,
        "bias_enabled": false,
        "random_walk_enabled": false,
        "delay_enabled": false,
        "gyro_noise_density": 0.0,
        "accelerometer_noise_density": 0.0,
        "gyro_bias": Vector3.ZERO,
        "accelerometer_bias": Vector3.ZERO,
        "gyro_bias_drift": 0.0,
        "accelerometer_bias_drift": 0.0,
        "gyro_random_walk": 0.0,
        "accelerometer_random_walk": 0.0,
        "barometer_noise": 0.0,
        "barometer_bias_drift": 0.0,
        "barometer_random_walk": 0.0,
        "sample_delay_frames": 0
    }
    native.call("configure_imu", quiet_config)
    if not _same_imu_config(native.call("imu_configuration"), quiet_config):
        push_error("AeroSimNative must echo disabled IMU noise/bias/random-walk/delay configuration")
        return false

    var noisy_config := {
        "noise_enabled": true,
        "bias_enabled": true,
        "random_walk_enabled": true,
        "delay_enabled": true,
        "gyro_noise_density": 0.003,
        "accelerometer_noise_density": 0.08,
        "gyro_bias": Vector3(0.01, -0.02, 0.03),
        "accelerometer_bias": Vector3(0.1, -0.2, 0.3),
        "gyro_bias_drift": 0.0002,
        "accelerometer_bias_drift": 0.003,
        "gyro_random_walk": 0.0004,
        "accelerometer_random_walk": 0.005,
        "barometer_noise": 0.12,
        "barometer_bias_drift": 0.01,
        "barometer_random_walk": 0.02,
        "sample_delay_frames": 2
    }
    native.call("configure_imu", noisy_config)
    if not _same_imu_config(native.call("imu_configuration"), noisy_config):
        push_error("AeroSimNative must echo enabled IMU noise/bias/random-walk/delay configuration")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("IMU public path should arm flight control from low throttle")
        return false
    native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.0, 0.0, 0.0)
    var diagnostics: Dictionary = native.call("flight_control_diagnostics")
    if diagnostics.get("uses_estimated_attitude", false) != true:
        push_error("Flight control diagnostics must prove attitude source is the IMU estimate, not truth")
        return false
    native.call("configure_imu", quiet_config)
    native.call("reset_flight")
    return true

func _same_imu_config(actual: Dictionary, expected: Dictionary) -> bool:
    for key in expected:
        if not actual.has(key) or not _same_imu_value(actual[key], expected[key]):
            return false
    return true

func _same_imu_value(actual: Variant, expected: Variant) -> bool:
    if expected is Vector3:
        return actual is Vector3 and actual.distance_to(expected) <= 1e-9
    if expected is bool:
        return actual == expected
    if expected is int:
        return int(actual) == expected
    return is_equal_approx(float(actual), float(expected))

func _verify_flight_control_public_path(native: Object) -> bool:
    native.call("reset_flight")
    var disarmed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if disarmed_row[2] > 0.0:
        push_error("Disarmed Angle Mode throttle must not produce lift")
        return false

    native.call("reset_flight")
    var bypass_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 1000.0)
    if bypass_row[2] > 0.0:
        push_error("Public step_simulation must not bypass arm safety with direct thrust")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Low throttle should arm flight control through Godot public path")
        return false
    var armed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if armed_row[2] <= disarmed_row[2]:
        push_error("Armed Angle Mode throttle should produce lift")
        return false

    native.call("reset_flight")
    if not native.call("flight_control_armed"):
        push_error("reset_flight should keep armed state for immediate throttle follow")
        return false
    var reset_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.0, 0.0, 0.0, 0.0)
    if int(reset_row[11]) <= 0:
        push_error("reset_flight should clear the substep clock before the next step")
        return false
    return true

func _verify_collision_public_path(native: Object) -> bool:
    native.call("reset_flight")
    native.call("set_collision_release_frames", 5)
    if not native.call("arm_flight_control", 0.0):
        push_error("Collision public path should arm from low throttle")
        return false

    var impact: PackedFloat64Array = _step_native_collision(
        native,
        0.5,
        true,
        Vector3.LEFT,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        -1.0
    )
    if impact.size() < 14 or int(impact[12]) != 1 or int(impact[13]) < 1:
        push_error("Collision public path must expose Jolt authority and integrator reset")
        return false

    var clear := PackedFloat64Array()
    for _frame in range(4):
        clear = _step_native_collision(
            native,
            0.8,
            false,
            Vector3.ZERO,
            Vector3.ZERO,
            Vector3.ZERO,
            Vector3.ZERO,
            -1.0
        )
    if clear.size() < 14 or int(clear[12]) != 1:
        push_error("Collision public path must respect configured no-contact release frames")
        return false
    clear = _step_native_collision(
        native,
        0.8,
        false,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        -1.0
    )
    if clear.size() < 14 or int(clear[12]) != 0:
        push_error("Collision public path must return to flight authority after configured clear frames")
        return false
    native.call("reset_flight")
    return true

func _verify_jolt_collision_scene(native: Object) -> bool:
    if ProjectSettings.get_setting("physics/3d/physics_engine", "") != "Jolt Physics":
        push_error("Project must lock physics/3d/physics_engine to Jolt Physics")
        return false

    verified_jolt_collision_trials = 0
    for scenario in ["wall", "glancing_ground", "pole", "tumble_ground"]:
        for seed in range(100):
            var first: Dictionary = await _run_jolt_collision_trial(native, scenario, seed)
            var second: Dictionary = await _run_jolt_collision_trial(native, scenario, seed)
            if not first.ok or not second.ok or not _same_collision_row(first.row, second.row):
                push_error("Headless Jolt G0.8 trial failed: %s seed %d first=%s second=%s" % [scenario, seed, first.get("reason", ""), second.get("reason", "")])
                return false
            verified_jolt_collision_trials += 1
    return true

func _run_jolt_collision_trial(native: Object, scenario: String, seed: int) -> Dictionary:
    var trial_root := Node3D.new()
    trial_root.name = "JoltCollisionTrial"
    root.add_child(trial_root)

    var drone = CollisionProbeBodyScript.new()
    drone.contact_monitor = true
    drone.max_contacts_reported = 4
    drone.gravity_scale = 0.0
    drone.set("continuous_cd", true)
    _add_shape(drone, _drone_shape(scenario))
    trial_root.add_child(drone)

    _setup_jolt_trial_geometry(trial_root, drone, scenario, seed)
    var energy_before := _kinetic(drone.linear_velocity, drone.angular_velocity)

    if drone.get("continuous_cd") != true:
        trial_root.queue_free()
        return {"ok": false, "row": PackedFloat64Array(), "reason": "ccd_off"}

    native.call("reset_flight")
    native.call("arm_flight_control", 0.0)
    var impact_row := PackedFloat64Array()
    var reason := "no_contact"
    for _frame in range(45):
        await physics_frame
        if drone.contact_seen:
            if not _vector_finite(drone.contact_normal) or drone.contact_normal.length() <= 0.0:
                reason = "bad_contact_normal"
                break
            if not _vector_finite(drone.contact_impulse) or drone.contact_impulse.length() <= 0.0:
                reason = "bad_contact_impulse"
                break
            _sync_native_from_body(native, drone)
            var solved_linear: Vector3 = drone.linear_velocity
            var solved_angular: Vector3 = drone.angular_velocity
            impact_row = _step_native_collision(
                native,
                0.5,
                true,
                drone.contact_normal,
                drone.contact_impulse,
                solved_linear,
                solved_angular,
                energy_before
            )
            reason = "impact"
            break

    var ok := impact_row.size() >= 24 and int(impact_row[12]) == 1 and int(impact_row[13]) >= 1
    if not ok and reason == "impact":
        reason = "handoff_row"
    ok = ok and _collision_row_finite(impact_row)
    if not ok and reason == "impact":
        reason = "impact_finite"
    ok = ok and _row_normal(impact_row).distance_to(drone.contact_normal) <= 1e-6
    if not ok and reason == "impact":
        reason = "normal_missing"
    ok = ok and _row_impulse(impact_row).length() > 0.0
    ok = ok and _row_impulse(impact_row).distance_to(drone.contact_impulse) <= 1e-6
    if not ok and reason == "impact":
        reason = "impulse_missing"
    ok = ok and float(impact_row[17]) <= energy_before * 1.01 + 1e-9
    if not ok and reason == "impact":
        reason = "energy row=%f limit=%f" % [float(impact_row[17]), energy_before * 1.01]
    if ok:
        _apply_collision_row_to_body(drone, impact_row)
        var body_energy := _kinetic(drone.linear_velocity, drone.angular_velocity)
        ok = _body_state_finite(drone) and body_energy <= energy_before * 1.01 + 1e-5
        if not ok:
            reason = "body_impact_state body=%f limit=%f finite=%s" % [body_energy, energy_before * 1.01, str(_body_state_finite(drone))]
    ok = ok and not (scenario == "wall" and drone.global_position.x > 0.3)
    if not ok and reason == "impact":
        reason = "tunneled"
    if ok:
        var clear := PackedFloat64Array()
        for _frame in range(3):
            await physics_frame
            _sync_native_from_body(native, drone)
            clear = _step_native_clear_collision(native, 0.8)
            _apply_collision_row_to_body(drone, clear)
        ok = clear.size() >= 24 and int(clear[12]) == 0
        if not ok:
            reason = "handoff_clear"
        var vertical_velocity_before_response := float(clear[9])
        for _frame in range(Engine.physics_ticks_per_second / 2):
            await physics_frame
            _sync_native_from_body(native, drone)
            clear = _step_native_clear_collision(native, 0.8)
            _apply_collision_row_to_body(drone, clear)
        ok = ok and clear.size() >= 18 and float(clear[9]) > vertical_velocity_before_response and _collision_row_finite(clear)
        if not ok and reason == "impact":
            reason = "response"
        if ok:
            _apply_collision_row_to_body(drone, clear)
            ok = _body_state_finite(drone) and drone.linear_velocity.y > vertical_velocity_before_response
            if not ok:
                reason = "body_response"
        impact_row = clear
    if ok:
        reason = "ok"

    trial_root.queue_free()
    await process_frame
    return {"ok": ok, "row": impact_row, "reason": reason}

func _step_native_clear_collision(native: Object, throttle: float) -> PackedFloat64Array:
    return _step_native_collision(
        native,
        throttle,
        false,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        -1.0
    )

func _step_native_collision(
    native: Object,
    throttle: float,
    touching: bool,
    normal: Vector3,
    impulse: Vector3,
    resolved_linear: Vector3,
    resolved_angular: Vector3,
    energy_limit: float
) -> PackedFloat64Array:
    return native.call(
        "step_collision_angle_mode",
        Engine.physics_ticks_per_second,
        1000,
        throttle,
        0.0,
        0.0,
        0.0,
        touching,
        normal.x,
        normal.y,
        normal.z,
        impulse.x,
        impulse.y,
        impulse.z,
        0.0,
        resolved_linear.x,
        resolved_linear.y,
        resolved_linear.z,
        resolved_angular.x,
        resolved_angular.y,
        resolved_angular.z,
        energy_limit
    )

func _setup_jolt_trial_geometry(parent: Node3D, drone: RigidBody3D, scenario: String, seed: int) -> void:
    if scenario == "wall":
        var wall := StaticBody3D.new()
        wall.position = Vector3.ZERO
        var wall_box := BoxShape3D.new()
        wall_box.size = Vector3(0.2, 2.0, 2.0)
        _add_shape(wall, wall_box)
        parent.add_child(wall)
        drone.position = Vector3(-1.0, _jitter(seed, 1, -0.05, 0.05), _jitter(seed, 2, -0.05, 0.05))
        drone.linear_velocity = Vector3(30.0 + _jitter(seed, 3, -0.25, 0.25), 0.0, 0.0)
    elif scenario == "glancing_ground":
        var ground := StaticBody3D.new()
        ground.position = Vector3.ZERO
        var ground_box := BoxShape3D.new()
        ground_box.size = Vector3(4.0, 0.1, 4.0)
        _add_shape(ground, ground_box)
        parent.add_child(ground)
        var speed := 20.0 + _jitter(seed, 4, -0.5, 0.5)
        var angle := deg_to_rad(5.0)
        drone.position = Vector3(-0.8, 0.16, _jitter(seed, 5, -0.05, 0.05))
        drone.linear_velocity = Vector3(speed * cos(angle), -speed * sin(angle), 0.0)
    elif scenario == "pole":
        var pole := StaticBody3D.new()
        pole.position = Vector3.ZERO
        var pole_shape := CylinderShape3D.new()
        pole_shape.radius = 0.08
        pole_shape.height = 2.0
        _add_shape(pole, pole_shape)
        parent.add_child(pole)
        var z_offset := _jitter(seed, 6, -0.12, 0.12)
        drone.position = Vector3(-1.0, 0.0, z_offset)
        drone.linear_velocity = Vector3(14.0, 0.0, -z_offset * 3.0)
    else:
        var tumble_ground := StaticBody3D.new()
        tumble_ground.position = Vector3.ZERO
        var tumble_box := BoxShape3D.new()
        tumble_box.size = Vector3(4.0, 0.1, 4.0)
        _add_shape(tumble_ground, tumble_box)
        parent.add_child(tumble_ground)
        drone.position = Vector3(_jitter(seed, 7, -0.2, 0.2), 0.8, _jitter(seed, 8, -0.2, 0.2))
        drone.linear_velocity = Vector3(_jitter(seed, 9, -2.0, 2.0), -8.0, _jitter(seed, 10, -2.0, 2.0))
        drone.angular_velocity = Vector3(_jitter(seed, 11, -9.0, 9.0), _jitter(seed, 12, -9.0, 9.0), _jitter(seed, 13, -9.0, 9.0))

func _drone_shape(scenario: String) -> Shape3D:
    if scenario == "tumble_ground":
        var box := BoxShape3D.new()
        box.size = Vector3(0.24, 0.08, 0.24)
        return box
    var sphere := SphereShape3D.new()
    sphere.radius = 0.1
    return sphere

func _add_shape(body: CollisionObject3D, shape: Shape3D) -> void:
    var collision_shape := CollisionShape3D.new()
    collision_shape.shape = shape
    body.add_child(collision_shape)

func _collision_row_finite(row: PackedFloat64Array) -> bool:
    if row.size() < 24:
        return false
    for index in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]:
        if not is_finite(row[index]):
            return false
    return true

func _apply_collision_row_to_body(body: Object, row: PackedFloat64Array) -> void:
    body.apply_native_state(
        Vector3(row[1], row[2], row[3]),
        Quaternion(row[4], row[5], row[6], row[7]),
        Vector3(row[8], row[9], row[10]),
        Vector3(row[14], row[15], row[16])
    )

func _sync_native_from_body(native: Object, body: RigidBody3D) -> void:
    var q := body.global_transform.basis.get_rotation_quaternion()
    native.call(
        "sync_flight_state",
        body.global_position.x,
        body.global_position.y,
        body.global_position.z,
        q.x,
        q.y,
        q.z,
        q.w,
        body.linear_velocity.x,
        body.linear_velocity.y,
        body.linear_velocity.z,
        body.angular_velocity.x,
        body.angular_velocity.y,
        body.angular_velocity.z
    )

func _row_impulse(row: PackedFloat64Array) -> Vector3:
    return Vector3(row[21], row[22], row[23])

func _row_normal(row: PackedFloat64Array) -> Vector3:
    return Vector3(row[18], row[19], row[20])

func _body_state_finite(body: RigidBody3D) -> bool:
    var q := body.global_transform.basis.get_rotation_quaternion()
    return _vector_finite(body.global_position) and _vector_finite(body.linear_velocity) and _vector_finite(body.angular_velocity) and is_finite(q.x) and is_finite(q.y) and is_finite(q.z) and is_finite(q.w)

func _same_collision_row(a: PackedFloat64Array, b: PackedFloat64Array) -> bool:
    if a.size() != b.size():
        return false
    for index in range(a.size()):
        if index == 13:
            continue
        if abs(a[index] - b[index]) > 1e-6:
            return false
    return true

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3) -> float:
    return 0.5 * linear_velocity.length_squared() + 0.5 * angular_velocity.length_squared()

func _vector_finite(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _jitter(seed: int, salt: int, low: float, high: float) -> float:
    var unit := fposmod(sin(float(seed * 31 + salt * 17)) * 43758.5453123, 1.0)
    return low + (high - low) * unit

func _verify_runtime_actions() -> bool:
    var scene := SmokeScene.instantiate()
    root.add_child(scene)
    await process_frame
    if scene.native == null:
        push_error("Smoke runtime must instantiate AeroSimNative")
        scene.queue_free()
        return false
    if not scene.last_profile_status.contains("KeyboardProfile"):
        push_error("Smoke runtime must expose no-controller KeyboardProfile fallback UI")
        scene.queue_free()
        return false
    if not scene.has_method("quick_fly"):
        push_error("Smoke runtime must expose Quick Fly from the cold-start main menu")
        scene.queue_free()
        return false
    if scene.main_menu_entries != ["Quick Fly", "Controller", "Drone", "Map", "Settings"]:
        push_error("Cold-start main menu must expose the fixed 3.5.4 first-layer entries")
        scene.queue_free()
        return false
    var quick_fly_button := scene.get_node_or_null("MainMenu/Entries/QuickFly") as Button
    if quick_fly_button == null or quick_fly_button.text != "Quick Fly":
        push_error("Cold-start main menu must expose an interactive Quick Fly button")
        scene.queue_free()
        return false
    quick_fly_button.pressed.emit()
    await process_frame
    if scene.screen != "flight" or not scene.takeoff_requested:
        push_error("Quick Fly button must enter the default drone/map flight scene")
        scene.queue_free()
        return false
    scene.quick_fly("uncalibrated")
    if scene.screen != "controller_setup":
        push_error("Quick Fly with an uncalibrated controller must route to Controller Setup")
        scene.queue_free()
        return false
    scene.quick_fly("drone_load_failed")
    if scene.screen != "error" or scene.last_error_message.is_empty():
        push_error("Quick Fly load failures must show an explicit error screen")
        scene.queue_free()
        return false
    scene.quick_fly("no_controller")
    if scene.screen != "fallback_prompt" or not scene.last_error_message.contains("KeyboardProfile"):
        push_error("Quick Fly without a controller must show an explicit KeyboardProfile fallback prompt")
        scene.queue_free()
        return false
    scene.accept_fallback()
    if scene.screen != "flight" or not scene.takeoff_requested:
        push_error("Quick Fly fallback must enter the default drone/map flight scene")
        scene.queue_free()
        return false

    await _press_key(KEY_T)
    for _frame in range(30):
        await physics_frame
        if scene.collision_handoff_count > 0:
            break
    if not scene.takeoff_requested or not scene.native.call("flight_control_armed"):
        push_error("flight_takeoff action must request takeoff and arm through runtime")
        scene.queue_free()
        return false
    if scene.collision_handoff_count <= 0:
        push_error("flight runtime must feed DroneBody Jolt contact into native collision authority")
        scene.queue_free()
        return false

    await _press_key(KEY_P)
    if not scene.paused:
        push_error("flight_pause action must pause runtime")
        scene.queue_free()
        return false
    var paused_position: Vector3 = scene.drone_body.global_position
    for _frame in range(5):
        await physics_frame
    if scene.drone_body.global_position.distance_to(paused_position) > 1e-6:
        push_error("flight_pause action must freeze runtime physics")
        scene.queue_free()
        return false
    await _press_key(KEY_P)
    if scene.paused:
        push_error("flight_pause action must resume runtime physics")
        scene.queue_free()
        return false

    await _press_key(KEY_R)
    if scene.reset_count != 1 or not scene.takeoff_requested or not scene.native.call("flight_control_armed"):
        push_error("flight_respawn action must reset while keeping flight armed and active")
        scene.queue_free()
        return false
    if scene.drone_body.position.distance_to(Vector3(-1.0, 0.0, 0.0)) > 1e-6 or scene.drone_body.linear_velocity.length() > 1e-6 or scene.drone_body.angular_velocity.length() > 1e-6:
        push_error("flight_respawn action must return to spawn and clear body velocity; position=%s linear=%s angular=%s" % [scene.drone_body.position, scene.drone_body.linear_velocity, scene.drone_body.angular_velocity])
        scene.queue_free()
        return false

    await _press_key(KEY_ESCAPE)
    if not scene.exit_requested:
        push_error("flight_exit action must request exit")
        scene.queue_free()
        return false

    scene.queue_free()
    return true

func _press_key(keycode: int) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = true
    Input.parse_input_event(event)
    await process_frame
    event = InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = false
    Input.parse_input_event(event)
    await process_frame

func _verify_keyboard_profile_actions() -> bool:
    var actions := {
        "flight_takeoff": KEY_T,
        "flight_pause": KEY_P,
        "flight_respawn": KEY_R,
        "flight_exit": KEY_ESCAPE
    }
    for action in actions:
        if not InputMap.has_action(action):
            push_error("KeyboardProfile missing InputMap action: %s" % action)
            return false

        var probe := InputProbe.new()
        probe.action = action
        probe.set_process_input(true)
        root.add_child(probe)
        await process_frame

        var event := InputEventKey.new()
        event.keycode = actions[action]
        event.physical_keycode = actions[action]
        event.pressed = true
        Input.parse_input_event(event)
        await process_frame
        if not probe.pressed:
            push_error("KeyboardProfile action did not trigger via Input.parse_input_event: %s" % action)
            probe.queue_free()
            return false

        event = InputEventKey.new()
        event.keycode = actions[action]
        event.physical_keycode = actions[action]
        event.pressed = false
        Input.parse_input_event(event)
        await process_frame
        probe.queue_free()
    return true

func _verify_gamepad_profile_actions() -> bool:
    var profile := InputProfiles.GamepadProfile.new()
    profile.apply_throttle_axis(0.7)
    profile.apply_throttle_axis(0.0)
    if not is_equal_approx(profile.throttle, 0.7):
        push_error("GamepadProfile throttle must be sticky when the stick returns to center")
        return false

    profile.apply_throttle_axis(0.02)
    if not is_equal_approx(profile.throttle, 0.7):
        push_error("GamepadProfile throttle deadzone must ignore small drift")
        return false

    var actions := {
        "flight_takeoff": JOY_BUTTON_A,
        "flight_pause": JOY_BUTTON_START,
        "flight_respawn": JOY_BUTTON_X,
        "flight_exit": JOY_BUTTON_B
    }
    for action in actions:
        if not InputMap.has_action(action):
            push_error("GamepadProfile missing InputMap action: %s" % action)
            return false

        var has_joypad_button := false
        for mapped_event in InputMap.action_get_events(action):
            if mapped_event is InputEventJoypadButton:
                has_joypad_button = true
                break
        if not has_joypad_button:
            push_error("GamepadProfile action lacks joypad binding: %s" % action)
            return false

        var probe := InputProbe.new()
        probe.action = action
        probe.set_process_input(true)
        root.add_child(probe)
        await process_frame

        var event := InputEventJoypadButton.new()
        event.button_index = actions[action]
        event.pressed = true
        Input.parse_input_event(event)
        await process_frame
        if not probe.pressed:
            push_error("GamepadProfile action did not trigger via Input.parse_input_event: %s" % action)
            probe.queue_free()
            return false

        event = InputEventJoypadButton.new()
        event.button_index = actions[action]
        event.pressed = false
        Input.parse_input_event(event)
        await process_frame
        probe.queue_free()
    return true

func _output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_smoke.json")

func _csv_output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--csv-output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_trajectory.csv")

func _requested_frames() -> int:
    var frames := _int_arg("--frames", 3)
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        frames = ceili(seconds * float(Engine.physics_ticks_per_second))
    return maxi(frames, 1)

func _requested_seconds(requested_frames: int) -> float:
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        return seconds
    return float(requested_frames) / float(Engine.physics_ticks_per_second)

func _write_trajectory_csv(path: String, trajectory: PackedFloat64Array, stride: int) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write trajectory CSV: %s" % path)
        return false

    file.store_line("time_s,position_x_m,position_y_m,position_z_m,orientation_x,orientation_y,orientation_z,orientation_w,velocity_x_mps,velocity_y_mps,velocity_z_mps,substeps")
    for row in range(int(trajectory.size() / stride)):
        var offset := row * stride
        var values: Array[String] = []
        for column in range(stride):
            values.append("%.10f" % trajectory[offset + column])
        file.store_line(",".join(values))
    return true

func _int_arg(name: String, default_value: int) -> int:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_int()
    return default_value

func _float_arg(name: String, default_value: float) -> float:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_float()
    return default_value

func _project_path(path: String) -> String:
    if path.is_absolute_path():
        return path
    return ProjectSettings.globalize_path("res://").path_join(path)
