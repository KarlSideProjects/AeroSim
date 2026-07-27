extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const Px4SitlBridge = preload("res://common/rpc/px4_sitl_bridge.gd")

var _runtime: FlightRuntime
var _server: GspServer
var _client := WebSocketPeer.new()
var _failures: Array[String] = []


func _init() -> void:
    _run()


func _run() -> void:
    _runtime = FlightRuntime.new()
    _runtime.native = ClassDB.instantiate("AeroSimNative")
    _runtime.airsim_session = AirSimSession.new(240)
    _runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    _runtime._airsim_vehicle_name = "DroneA"
    var hardware := HardwareConfig.new()
    _runtime._gsp_tuning_registry = hardware.tuning_registry()
    _runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(_runtime.native != null, "runtime uses the registered native controller")
    if _runtime.native == null:
        _finish()
        return
    var initialized: Dictionary = _runtime.native.call(
            "initialize_flight_tuning", "simpleflight.rate_p", 0.6)
    _expect(bool(initialized.get("ok", false)) and int(initialized.get("commit_id", -1)) == 0,
            "native defaults initialize without a tuning commit")
    _expect(hardware.apply_to_runtime(_runtime, "res://config/drones/5_inch_6s.json"),
            "integration runtime applies the canonical hardware preset")
    var native_contract: Dictionary = _runtime.native.call("flight_tuning_contract")
    var descriptor: Dictionary = _runtime._gsp_tuning_registry[0]
    for key in ["key", "type", "default", "min", "max"]:
        _expect(native_contract.get(key) == descriptor.get(key), "schema/native tuning contract agrees on %s" % key)

    _server = GspServer.new()
    root.add_child(_server)
    _server.set_identity_provider(Callable(_runtime, "gsp_identity_snapshot"))
    _server.set_tuning_request_provider(Callable(_runtime, "gsp_tuning_request"))
    _server.set_tuning_result_provider(Callable(_runtime, "gsp_tuning_results"))
    var started := _server.start()
    _server.set_process(false)
    _expect(bool(started.get("ok", false)), "runtime GSP server starts")
    if not bool(started.get("ok", false)):
        _finish()
        return
    await _connect_and_auth(_client, int(started.port), String(started.token))
    var hello := await _next_message_type(_client, "hello", 240)
    var hello_data: Dictionary = hello.get("d", {})
    _expect(typeof(hello_data.get("registry", {}).get("tuning", {})) == TYPE_DICTIONARY,
            "hello carries active tuning reconciliation metadata")

    _runtime.paused = false
    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.25}
    })) == OK, "active tuning request sends")
    _server.poll()
    _client.poll()
    var before_active: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(before_active.get("simpleflight.rate_p", 0.0) == 0.6 and _client.get_available_packet_count() == 0,
            "active tuning remains staged until the next physics boundary")
    _runtime._physics_process(1.0 / 240.0)
    var after_active: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(after_active.get("simpleflight.rate_p", 0.0) == 1.25 and int(after_active.get("commit_id", 0)) == 1,
            "active tuning commits through native active memory")
    _expect(int(after_active.get("commit_tick", -1)) == 0, "active tuning reports public frame tick zero")
    var active_ack := await _next_message_type(_client, "tuning_ack", 240)
    _expect(int(active_ack.get("d", {}).get("request_seq", -1)) == 1 and bool(active_ack.get("d", {}).get("changed", false)),
            "active tuning ack preserves request correlation and changed outcome")

    _runtime.paused = true
    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 2,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.5}
    })) == OK, "paused tuning request sends")
    var paused_ack := await _next_message_type(_client, "tuning_ack", 240)
    var paused_data: Dictionary = paused_ack.get("d", {})
    _expect(int(paused_data.get("request_seq", -1)) == 2 and int(paused_data.get("commit_id", 0)) == 2 and
            int(paused_data.get("commit_tick", -1)) == 1,
            "paused tuning commits immediately through the same native operation")

    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 3,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.5}
    })) == OK, "no-op tuning request sends")
    var noop_ack := await _next_message_type(_client, "tuning_ack", 240)
    var noop_data: Dictionary = noop_ack.get("d", {})
    _expect(not bool(noop_data.get("changed", true)) and int(noop_data.get("commit_id", 0)) == 2,
            "no-op tuning keeps commit ID and reports changed false")

    var before_rejection: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 4,
        "d": {"parameter": "unknown", "value": 1.0}
    })) == OK, "unknown tuning request sends")
    var rejected_ack := await _next_message_type(_client, "tuning_ack", 240)
    _expect(String(rejected_ack.get("d", {}).get("error", "")) == "unknown_parameter",
            "unknown tuning parameter is rejected")
    var after_rejection: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(after_rejection.get("simpleflight.rate_p", 0.0) == before_rejection.get("simpleflight.rate_p", -1.0) and
            int(after_rejection.get("commit_id", -1)) == int(before_rejection.get("commit_id", -2)),
            "rejected tuning does not mutate active memory")

    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 5,
        "d": {"parameter": "simpleflight.rate_p", "value": 3.0}
    })) == OK, "clamped tuning request sends")
    var clamp_ack := await _next_message_type(_client, "tuning_ack", 240)
    var clamp_data: Dictionary = clamp_ack.get("d", {})
    _expect(bool(clamp_data.get("clamped", false)) and float(clamp_data.get("requested_value", 0.0)) == 3.0 and
            float(clamp_data.get("committed_value", 0.0)) == 2.0,
            "clamping reports requested and committed values")

    var wrong_type: Dictionary = _runtime.native.call("stage_flight_tuning", "simpleflight.rate_p", "bad")
    var non_finite: Dictionary = _runtime.native.call("stage_flight_tuning", "simpleflight.rate_p", NAN)
    _expect(String(wrong_type.get("error", "")) == "wrong_type" and String(non_finite.get("error", "")) == "non_finite",
            "native rejects wrong-type and non-finite staging inputs")

    var bridge := Px4SitlBridge.new()
    bridge._authority_active = true
    bridge.state = "connected"
    _runtime.px4_sitl_bridge = bridge
    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 6,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.0}
    })) == OK, "external-authority tuning request sends")
    var authority_ack := await _next_message_type(_client, "tuning_ack", 240)
    _expect(String(authority_ack.get("d", {}).get("error", "")) == "external_authority",
            "native rejects tuning under external authority")
    _runtime.px4_sitl_bridge = null
    _runtime._sync_native_external_authority()

    _client.close()
    for _attempt in 30:
        _server.poll()
        await process_frame
    var reconnect_client := WebSocketPeer.new()
    await _connect_and_auth(reconnect_client, int(started.port), String(started.token))
    var reconnect_hello := await _next_message_type(reconnect_client, "hello", 240)
    var reconciled: Dictionary = reconnect_hello.get("d", {}).get("registry", {}).get("tuning", {})
    _expect(int(reconciled.get("commit_id", -1)) == 3 and int(reconciled.get("commit_tick", -1)) == 1 and
            float(reconciled.get("committed_value", 0.0)) == 2.0,
            "reconnect hello reconciles latest active tuning state")
    _expect(not reconnect_hello.get("d", {}).get("registry", {}).get("tuning_recent_results", []).is_empty(),
            "reconnect hello carries bounded recent tuning results")

    _runtime._replay_recording_active = true
    var config_json := _runtime._replay_canonical_json(_runtime.native.call("replay_vehicle_config_manifest"))
    var config_hash := String(_runtime.native.call("replay_manifest_hash", config_json))
    var begin: Dictionary = _runtime.native.call(
            "begin_complete_replay_recording", 11, "tuning-settings", "DroneA", config_hash, config_json, 0,
            "DroneB", config_hash, config_json, 0)
    _expect(bool(begin.get("ok", false)), "runtime native replay recorder starts")
    var atmosphere := {
        "rain": 0.0,
        "atmosphere": _runtime.native.call("wind_configuration"),
        "atmosphere_air_density_kg_m3": float(_runtime.native.call("body_drag_configuration").get("air_density_kg_m3", 1.225)),
    }
    var environment_result: Dictionary = _runtime.native.call(
            "record_replay_environment", 0, _runtime._replay_canonical_json(atmosphere))
    _expect(bool(environment_result.get("ok", false)),
            "runtime replay recorder accepts the atmosphere baseline: %s" % String(environment_result.get("diagnostic_message", "unknown")))
    _expect(reconnect_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.0}
    })) == OK, "replay tuning request sends")
    var replay_ack := await _next_message_type(reconnect_client, "tuning_ack", 240)
    _expect(bool(replay_ack.get("d", {}).get("changed", false)), "replay tuning request commits a real change")
    var finish: Dictionary = _runtime.native.call("finish_complete_replay_recording", 100000, "tuning-test")
    _runtime._replay_recording_active = false
    var serialized := String(finish.get("serialized", ""))
    _expect(bool(finish.get("ok", false)) and serialized.contains("\"type\":\"tuning\""),
            "changed tuning is recorded as a replay input: %s" % String(finish.get("diagnostic_message", "missing tuning event")))
    var replay: Dictionary = _runtime.native.call(
            "replay_complete_session", serialized, "tuning-settings", config_hash, config_hash,
            _runtime.native.call("replay_vehicle_config_manifest"), _runtime.native.call("replay_vehicle_config_manifest"))
    _expect(bool(replay.get("ok", false)), "recorded tuning replay applies successfully: %s" % String(replay.get("diagnostic_message", "unknown")))

    reconnect_client.close()
    _server.stop()
    _finish()


func _connect_and_auth(client: WebSocketPeer, port: int, token: String) -> void:
    client.handshake_headers = PackedStringArray(["Origin: null"])
    client.connect_to_url("ws://127.0.0.1:%d" % port)
    for _attempt in 240:
        _server.poll()
        client.poll()
        if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
            break
        await process_frame
    client.send_text(JSON.stringify({"v": 2, "t": "auth", "seq": 0, "d": {"token": token}}))


func _next_message_type(client: WebSocketPeer, message_type: String, attempts: int) -> Dictionary:
    for _attempt in attempts:
        _server.poll()
        client.poll()
        while client.get_available_packet_count() > 0:
            var packet := client.get_packet()
            if not client.was_string_packet():
                continue
            var parsed = JSON.parse_string(packet.get_string_from_utf8())
            if typeof(parsed) == TYPE_DICTIONARY and String(parsed.get("t", "")) == message_type:
                return parsed
        await process_frame
    return {}


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _finish() -> void:
    if _failures.is_empty():
        print("GSP tuning integration: PASS")
        quit(0)
    else:
        for failure in _failures:
            push_error(failure)
        print("GSP tuning integration: FAIL")
        quit(1)
