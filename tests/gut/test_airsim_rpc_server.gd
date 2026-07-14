extends GutTest

const AirSimRpcServer = preload("res://common/rpc/airsim_rpc_server.gd")
const MsgpackCodec = preload("res://common/rpc/msgpack_codec.gd")


func test_loopback_is_the_only_allowed_bind_address() -> void:
    var server := AirSimRpcServer.new()
    autofree(server)

    assert_true(server.validate_bind_address("127.0.0.1").ok)
    assert_false(server.validate_bind_address("0.0.0.0").ok)
    assert_false(server.validate_bind_address("192.168.1.10").ok)


func test_default_port_is_the_frozen_airsim_port() -> void:
    assert_eq(AirSimRpcServer.DEFAULT_PORT, 41451)
    assert_eq(AirSimRpcServer.MAX_CLIENT_BUFFER_BYTES, 1_048_576)


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
    assert_true(manifest["supported_api"].has("simContinueForFrames"))
    assert_true(manifest["settings"]["root"].has("Vehicles"))


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
