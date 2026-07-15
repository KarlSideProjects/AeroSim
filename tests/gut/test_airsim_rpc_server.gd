extends GutTest

const AirSimRpcServer = preload("res://common/rpc/airsim_rpc_server.gd")
const MsgpackCodec = preload("res://common/rpc/msgpack_codec.gd")

var command_calls: Array = []


func _install_test_backend(server: AirSimRpcServer) -> void:
    server.set_vehicle_backend(
        Callable(self, "_test_state"),
        Callable(self, "_test_command"),
        Callable(self, "_test_api_control"),
        Callable(self, "_test_arm"),
        Callable(self, "_test_cancel")
    )
    server.set_sensor_backend(Callable(self, "_test_sensor"))


func _test_api_control(_enabled: bool, _name: String) -> Dictionary:
    return {"ok": true}


func _test_arm(armed: bool, _name: String) -> Dictionary:
    return {"ok": true, "armed": armed}


func _test_command(_method: String, _params: Array, _name: String) -> Dictionary:
    command_calls.append([_method, _name])
    return {"ok": true}


func _test_cancel(_name: String) -> void:
    pass


func _test_sensor(sensor_type: int, sensor_name: String, _vehicle_name: String) -> Dictionary:
    return {"ok": true, "sensor": {"sensor_type": sensor_type, "sensor_name": sensor_name, "time_stamp": 42}}


func _test_state(_name: String) -> Dictionary:
    return {"ok": true, "state": {
        "collision": {"has_collided": false, "normal": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "impact_point": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "position": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "penetration_depth": 0.0, "time_stamp": 0, "object_name": "", "object_id": -1},
        "kinematics_estimated": {"position": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "orientation": {"w_val": 1.0, "x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "linear_velocity": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "angular_velocity": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "linear_acceleration": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}, "angular_acceleration": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0}},
        "gps_location": {"latitude": 0.0, "longitude": 0.0, "altitude": 0.0}, "timestamp": 0, "landed_state": 0, "rc_data": {}, "ready": true, "ready_message": "", "can_arm": true,
    }}


func test_loopback_is_the_only_allowed_bind_address() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)

    assert_true(server.validate_bind_address("127.0.0.1").ok)
    assert_false(server.validate_bind_address("0.0.0.0").ok)
    assert_false(server.validate_bind_address("192.168.1.10").ok)


func test_default_port_is_the_frozen_airsim_port() -> void:
    assert_eq(AirSimRpcServer.DEFAULT_PORT, 41451)
    assert_eq(AirSimRpcServer.MAX_CLIENT_BUFFER_BYTES, 1_048_576)


func test_reset_vehicle_control_state_clears_api_and_armed_latches() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41459,
        "RpcEnabled": false,
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}},
    })
    assert_true(startup.ok)
    server._api_control["Drone1"] = true
    server._armed["Drone1"] = true

    server.reset_vehicle_control_state()

    assert_false(server._api_control["Drone1"])
    assert_false(server._armed["Drone1"])


func test_non_loopback_start_is_rejected_before_listening() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)

    var result: Dictionary = server.start("0.0.0.0", AirSimRpcServer.DEFAULT_PORT)

    assert_false(result.ok)
    assert_false(server.is_running())


func test_dispatches_ping_and_pause_state_queries() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)

    assert_eq(server.dispatch([0, 1, "ping", []]), [1, 1, null, true])
    assert_eq(server.dispatch([0, 2, "simPause", [true]]), [1, 2, null, null])
    assert_eq(server.dispatch([0, 3, "simIsPaused", []]), [1, 3, null, true])


func test_dispatches_explicit_frame_step_and_rejects_unknown_methods() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    server.dispatch([0, 1, "simPause", [true]])

    var step_response: Array = server.dispatch([0, 2, "simContinueForFrames", [4]])
    assert_eq(step_response[0], 1)
    assert_eq(step_response[1], 2)
    assert_eq(step_response[2], null)
    assert_eq(step_response[3], null)

    var unknown: Array = server.dispatch([0, 3, "futureApi", []])
    assert_eq(unknown[0], 1)
    assert_eq(unknown[1], 3)
    assert_string_contains(unknown[2], "unsupported RPC method")


func test_loopback_transport_dispatches_one_messagepack_request() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var start_result: Dictionary = server.start(AirSimRpcServer.DEFAULT_BIND_ADDRESS, 41452)
    assert_true(start_result.ok)
    if not start_result.ok:
        return

    var client := StreamPeerTCP.new()
    autofree(client)
    assert_eq(client.connect_to_host(AirSimRpcServer.DEFAULT_BIND_ADDRESS, 41452), OK)
    for _attempt in 20:
        server.poll()
        client.poll()
        if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
            break
        await get_tree().process_frame
    assert_eq(client.get_status(), StreamPeerTCP.STATUS_CONNECTED)
    if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        return

    assert_eq(client.put_data(MsgpackCodec.encode([0, 9, "ping", []])), OK)
    var response_bytes := PackedByteArray()
    for _attempt in 20:
        server.poll()
        client.poll()
        if client.get_available_bytes() > 0:
            var data_result: Array = client.get_data(client.get_available_bytes())
            assert_eq(data_result[0], OK)
            response_bytes.append_array(data_result[1])
            break
        await get_tree().process_frame

    var response: Dictionary = MsgpackCodec.decode(response_bytes)
    assert_true(response.ok)
    assert_eq(response.value, [1, 9, null, true])
    server.stop()


func test_messagepack_preserves_binary_image_payloads() -> void:
    var payload := [0, 21, "image", [PackedByteArray([0, 1, 2, 255])]]
    var decoded: Dictionary = MsgpackCodec.decode(MsgpackCodec.encode(payload))

    assert_true(decoded.ok)
    assert_true(decoded.value[3][0] is PackedByteArray)
    assert_eq(decoded.value[3][0], PackedByteArray([0, 1, 2, 255]))


func test_manifest_names_the_current_compatibility_surface() -> void:
    var file := FileAccess.open("res://config/airsim_compatibility_manifest.json", FileAccess.READ)
    assert_not_null(file)
    if file == null:
        return
    var manifest = JSON.parse_string(file.get_as_text())
    assert_true(manifest is Dictionary)
    assert_eq(manifest["airsim_client"], "1.8.1")
    assert_eq(manifest["settings_version"], 1.2)
    assert_eq(manifest["transport"], "msgpack-rpc")
    assert_string_contains(manifest["storage"], "never persisted")
    assert_true(manifest["supported_api"].has("ping"))
    assert_true(manifest["supported_api"].has("getMultirotorState"))
    assert_true(manifest["supported_api"].has("simContinueForFrames"))
    assert_true(manifest["supported_api"].has("simGetImages"))
    assert_true(manifest["settings"]["root"].has("Vehicles"))


func test_sim_get_images_preserves_request_order_and_encoding_contract() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var camera_surface := FakeCameraSurface.new()
    server.set_camera_backend(Callable(camera_surface, "capture"))
    server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41455,
        "RpcEnabled": false,
    })

    var response: Array = server.dispatch([0, 11, "simGetImages", [[
        {"camera_name": "front_center", "image_type": 5, "pixels_as_float": false, "compress": true},
        {"camera_name": "front_center", "image_type": 1, "pixels_as_float": true, "compress": false},
        {"camera_name": "front_center", "image_type": 0, "pixels_as_float": false, "compress": false},
    ], "", false]])

    assert_eq(response[2], null)
    assert_eq(response[3].size(), 3)
    assert_eq(response[3][0]["image_type"], 5)
    assert_eq(response[3][1]["image_type"], 1)
    assert_eq(response[3][2]["image_type"], 0)
    assert_true(response[3][0]["image_data_uint8"] is PackedByteArray)
    assert_true(response[3][1]["image_data_float"] is PackedFloat32Array)
    assert_eq(response[3][2]["compress"], false)


func test_sim_get_images_rejects_unsupported_types_and_bad_requests() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var camera_surface := FakeCameraSurface.new()
    server.set_camera_backend(Callable(camera_surface, "capture"))

    var unsupported: Array = server.dispatch([0, 12, "simGetImages", [[
        {"camera_name": "0", "image_type": 3, "pixels_as_float": false, "compress": true}
    ], "", false]])
    assert_string_contains(unsupported[2], "unsupported")

    var malformed: Array = server.dispatch([0, 13, "simGetImages", [{"camera_name": "0"}, "", false]])
    assert_string_contains(malformed[2], "requests must be an array")


class FakeCameraSurface extends RefCounted:
    func capture(requests: Array, _vehicle_name: String, _external: bool) -> Dictionary:
        if requests.size() == 0:
            return {"ok": true, "responses": []}
        if typeof(requests[0]) != TYPE_DICTIONARY:
            return {"ok": false, "error": "requests must be an array of ImageRequest maps"}
        for request in requests:
            if int(request.get("image_type", -1)) not in [0, 1, 5]:
                return {"ok": false, "error": "unsupported image type"}
        var responses: Array = []
        for request in requests:
            var image_type := int(request["image_type"])
            var item := {
                "image_data_uint8": PackedByteArray([137, 80, 78, 71]) if not bool(request.get("pixels_as_float", false)) else PackedByteArray(),
                "image_data_float": PackedFloat32Array([1.0]) if bool(request.get("pixels_as_float", false)) else PackedFloat32Array(),
                "camera_position": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
                "camera_name": String(request.get("camera_name", "0")),
                "camera_orientation": {"w_val": 1.0, "x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
                "time_stamp": 0,
                "message": "",
                "pixels_as_float": bool(request.get("pixels_as_float", false)),
                "compress": bool(request.get("compress", true)),
                "width": 1,
                "height": 1,
                "image_type": image_type,
            }
            responses.append(item)
        return {"ok": true, "responses": responses}


func test_start_with_settings_validates_before_opening_listener() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)

    var result: Dictionary = server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41453,
        "RpcEnabled": true
    })

    assert_true(result.ok)
    assert_true(server.is_running())
    assert_eq(server.settings["ApiServerPort"], 41453)
    var settings_response: Array = server.dispatch([0, 10, "getSettingsString", []])
    assert_eq(settings_response[3], JSON.stringify(server.settings))
    server.stop()


func test_player_snapshot_mutation_cannot_change_startup_settings() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var player_snapshot := {
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41454,
        "RpcEnabled": true,
    }

    var result: Dictionary = server.start_with_settings(player_snapshot)
    assert_true(result.ok)
    player_snapshot["ApiServerPort"] = 41455
    assert_eq(server.settings["ApiServerPort"], 41454)
    server.stop()


func test_single_vehicle_control_and_state_use_the_frozen_airsim_payload() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41455,
        "RpcEnabled": false,
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}},
    })
    assert_true(startup.ok)
    _install_test_backend(server)

    assert_eq(server.dispatch([0, 20, "listVehicles", []]), [1, 20, null, ["Drone1"]])
    assert_eq(server.dispatch([0, 21, "enableApiControl", [true, "Drone1"]]), [1, 21, null, null])
    assert_eq(server.dispatch([0, 22, "isApiControlEnabled", ["Drone1"]]), [1, 22, null, true])
    assert_eq(server.dispatch([0, 23, "armDisarm", [true, "Drone1"]]), [1, 23, null, true])

    var state_response: Array = server.dispatch([0, 24, "getMultirotorState", ["Drone1"]])
    assert_eq(state_response[0], 1)
    assert_eq(state_response[2], null)
    assert_eq(state_response[3]["landed_state"], 0)
    assert_true(state_response[3]["ready"])
    assert_true(state_response[3]["can_arm"])
    assert_eq(state_response[3]["kinematics_estimated"]["position"], {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0})

    var pwm_response: Array = server.dispatch([0, 25, "moveByMotorPWMs", [0.5, 0.5, 0.5, 0.5, 1.0, "Drone1"]])
    assert_eq(pwm_response[0], 1)
    assert_string_contains(pwm_response[2], "per-motor PWM")


func test_two_named_vehicles_keep_api_control_and_commands_isolated() -> void:
    command_calls.clear()
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41460,
        "RpcEnabled": false,
        "Vehicles": {
            "DroneA": {"VehicleType": "SimpleFlight"},
            "DroneB": {"VehicleType": "SimpleFlight"},
        },
    })
    assert_true(startup.ok, startup.error)
    _install_test_backend(server)

    assert_eq(server.dispatch([0, 61, "listVehicles", []]), [1, 61, null, ["DroneA", "DroneB"]])
    assert_eq(server.dispatch([0, 62, "enableApiControl", [true, "DroneA"]]), [1, 62, null, null])
    assert_eq(server.dispatch([0, 63, "enableApiControl", [true, "DroneB"]]), [1, 63, null, null])
    assert_eq(server.dispatch([0, 64, "armDisarm", [true, "DroneA"]]), [1, 64, null, true])
    assert_eq(server.dispatch([0, 65, "armDisarm", [true, "DroneB"]]), [1, 65, null, true])

    assert_eq(server.dispatch([0, 66, "hover", ["DroneA"]]), [1, 66, null, null])
    assert_eq(server.dispatch([0, 67, "moveByVelocity", [1.0, 0.0, 0.0, 0.5, 0, {"is_rate": true, "yaw_or_rate": 0.0}, "DroneB"]]), [1, 67, null, null])
    assert_eq(command_calls, [["hover", "DroneA"], ["moveByVelocity", "DroneB"]])
    assert_true(server.dispatch([0, 68, "isApiControlEnabled", ["DroneA"]])[3])
    assert_true(server.dispatch([0, 69, "isApiControlEnabled", ["DroneB"]])[3])
    assert_string_contains(server.dispatch([0, 70, "hover", [""]])[2], "required")
    assert_string_contains(server.dispatch([0, 71, "hover", ["DroneC"]])[2], "unknown")


func test_vehicle_commands_require_control_and_preserve_ned_state_payloads() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41456,
        "RpcEnabled": false,
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}},
    })
    assert_true(startup.ok)
    _install_test_backend(server)

    var blocked: Array = server.dispatch([0, 30, "takeoff", [20.0, "Drone1"]])
    assert_string_contains(blocked[2], "API control")
    server.dispatch([0, 31, "enableApiControl", [true, "Drone1"]])
    server.dispatch([0, 32, "armDisarm", [true, "Drone1"]])

    assert_eq(server.dispatch([0, 33, "takeoff", [20.0, "Drone1"]]), [1, 33, null, null])
    var move_to_position: Array = server.dispatch([0, 34, "moveToPosition", [1.0, -2.0, -3.0, 5.0, 10.0, 0, {"is_rate": true, "yaw_or_rate": 0.0}, -1.0, 1, "Drone1"]])
    assert_eq(move_to_position, [1, 34, null, null])

    var velocity: Array = server.dispatch([0, 35, "moveByVelocity", [2.0, 3.0, -4.0, 1.0, 0, {"is_rate": true, "yaw_or_rate": 0.0}, "Drone1"]])
    assert_eq(velocity, [1, 35, null, null])
    var unsupported_drivetrain: Array = server.dispatch([0, 350, "moveByVelocity", [2.0, 3.0, -4.0, 1.0, 1, {"is_rate": true, "yaw_or_rate": 0.0}, "Drone1"]])
    assert_string_contains(unsupported_drivetrain[2], "ForwardOnly is unsupported")
    assert_eq(server.dispatch([0, 351, "moveByVelocityBodyFrame", [4.0, 5.0, 6.0, 1.0, 0, {"is_rate": true, "yaw_or_rate": 0.0}, "Drone1"]]), [1, 351, null, null])
    var invalid_path: Array = server.dispatch([0, 352, "moveOnPath", [[{"x_val": NAN, "y_val": 0.0, "z_val": 0.0}], 1.0, 1.0, 0, {"is_rate": true, "yaw_or_rate": 0.0}, -1.0, 1, "Drone1"]])
    assert_string_contains(invalid_path[2], "Vector3r")
    var state: Dictionary = server.dispatch([0, 36, "getMultirotorState", ["Drone1"]])[3]
    assert_eq(state["landed_state"], 0)
    assert_eq(state["kinematics_estimated"]["position"], {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0})

    assert_eq(server.dispatch([0, 37, "land", [60.0, "Drone1"]]), [1, 37, null, null])
    assert_eq(server.dispatch([0, 39, "reset", []]), [1, 39, null, null])
    assert_eq(server.dispatch([0, 391, "isApiControlEnabled", ["Drone1"]]), [1, 391, null, false])


func test_baseline_sensor_methods_preserve_pinned_client_payload_dispatch() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41459,
        "RpcEnabled": false,
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}},
    })
    assert_true(startup.ok)
    _install_test_backend(server)

    for request in [
        ["getImuData", 2],
        ["getGpsData", 3],
        ["getMagnetometerData", 4],
        ["getBarometerData", 1],
        ["getLidarData", 6],
    ]:
        var response: Array = server.dispatch([0, 60 + int(request[1]), request[0], ["", "Drone1"]])
        assert_eq(response[0], 1)
        assert_eq(response[2], null)
        assert_eq(response[3]["sensor_type"], request[1])

    var invalid: Array = server.dispatch([0, 70, "getImuData", ["only-one-argument"]])
    assert_string_contains(invalid[2], "sensor_name and vehicle_name")


func test_async_vehicle_response_waits_for_a_simulation_frame() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41457,
        "RpcEnabled": true,
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}},
    })
    assert_true(startup.ok)
    _install_test_backend(server)
    server.dispatch([0, 40, "enableApiControl", [true, "Drone1"]])
    server.dispatch([0, 41, "armDisarm", [true, "Drone1"]])
    server.session.set_paused(true)

    var client := StreamPeerTCP.new()
    autofree(client)
    assert_eq(client.connect_to_host(AirSimRpcServer.DEFAULT_BIND_ADDRESS, 41457), OK)
    for _attempt in 20:
        server.poll()
        client.poll()
        if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
            break
        await get_tree().process_frame
    assert_eq(client.get_status(), StreamPeerTCP.STATUS_CONNECTED)
    if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        server.stop()
        return

    assert_eq(client.put_data(MsgpackCodec.encode([0, 42, "takeoff", [20.0, "Drone1"]])), OK)
    for _attempt in 3:
        server.poll()
        client.poll()
        await get_tree().process_frame
    assert_eq(client.get_available_bytes(), 0)

    assert_true(server.session.continue_for_frames(1).ok)
    assert_true(server.session.advance_frame())
    server.poll()
    client.poll()
    assert_gt(client.get_available_bytes(), 0)
    var response: Dictionary = MsgpackCodec.decode(client.get_data(client.get_available_bytes())[1])
    assert_eq(response.value, [1, 42, null, true])

    assert_eq(client.put_data(MsgpackCodec.encode([0, 43, "moveToPosition", [1.0, 0.0, -1.0, 1.0, 0.0, 0, {"is_rate": true, "yaw_or_rate": 0.0}, -1.0, 1, "Drone1"]])), OK)
    server.poll()
    assert_true(server.session.continue_for_frames(1).ok)
    assert_true(server.session.advance_frame())
    server.poll()
    client.poll()
    var timeout_response: Dictionary = MsgpackCodec.decode(client.get_data(client.get_available_bytes())[1])
    assert_eq(timeout_response.value, [1, 43, null, false])
    server.stop()


func test_cancel_last_task_removes_a_pending_vehicle_command() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)
    var startup := server.start_with_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": 41458,
        "RpcEnabled": true,
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}},
    })
    assert_true(startup.ok)
    _install_test_backend(server)
    server.dispatch([0, 50, "enableApiControl", [true, "Drone1"]])
    server.dispatch([0, 51, "armDisarm", [true, "Drone1"]])
    server.session.set_paused(true)

    var client := StreamPeerTCP.new()
    autofree(client)
    assert_eq(client.connect_to_host(AirSimRpcServer.DEFAULT_BIND_ADDRESS, 41458), OK)
    for _attempt in 20:
        server.poll()
        client.poll()
        if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
            break
        await get_tree().process_frame
    if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        server.stop()
        return

    assert_eq(client.put_data(MsgpackCodec.encode([0, 52, "takeoff", [20.0, ""]])), OK)
    server.poll()
    assert_eq(server._pending_async_responses.size(), 1)
    assert_eq(server.dispatch([0, 53, "cancelLastTask", [""]]), [1, 53, null, null])
    assert_eq(server._pending_async_responses.size(), 0)
    server.poll()
    client.poll()
    assert_gt(client.get_available_bytes(), 0)
    var cancelled_response: Dictionary = MsgpackCodec.decode(client.get_data(client.get_available_bytes())[1])
    assert_eq(cancelled_response.value, [1, 52, null, false])
    server.stop()
