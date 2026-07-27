extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")

var _runtime: FlightRuntime
var _server: GspServer
var _client := WebSocketPeer.new()
var _failures: Array[String] = []


func _init() -> void:
    await _run()


func _run() -> void:
    _remove_known()
    _runtime = FlightRuntime.new()
    _runtime.native = ClassDB.instantiate("AeroSimNative")
    _runtime.airsim_session = AirSimSession.new(240)
    _runtime._airsim_vehicle_name = "DroneA"
    _runtime._airsim_vehicle_names = ["DroneA"]
    var hardware := HardwareConfig.new()
    _runtime._gsp_tuning_registry = hardware.tuning_registry()
    _runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(_runtime.native != null and hardware.initialize_tuning(_runtime), "preset integration initializes native tuning")
    if _runtime.native == null:
        _finish()
        return

    _server = GspServer.new()
    root.add_child(_server)
    _server.set_identity_provider(Callable(_runtime, "gsp_identity_snapshot"))
    _server.set_tuning_request_provider(Callable(_runtime, "gsp_tuning_request"))
    _server.set_tuning_result_provider(Callable(_runtime, "gsp_tuning_results"))
    _server.set_preset_request_provider(Callable(_runtime, "gsp_preset_request"))
    var started: Dictionary = _server.start()
    _server.set_process(false)
    _expect(bool(started.get("ok", false)), "preset GSP server starts")
    if not bool(started.get("ok", false)):
        _finish()
        return
    await _connect_and_auth(_client, int(started.port), String(started.token))
    _expect(not (await _next_message_type("hello", 240)).is_empty(), "preset client receives hello")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "save_preset", "seq": 1, "d": {"name": "integration_a", "note": "first"}})) == OK,
            "preset save request sends")
    _server.poll()
    var saved: Dictionary = await _next_message_type("preset_ack", 240)
    _expect(bool(saved.get("d", {}).get("ok", false)) and saved.get("d", {}).get("preset", {}).get("name", "") == "integration_a",
            "preset save returns metadata")

    _runtime.paused = true
    _expect(bool(_runtime.gsp_tuning_request(-1, -1, 1, "simpleflight.rate_p", 1.2).get("ok", false)),
            "integration mutates current through tuning authority")
    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "save_preset", "seq": 2, "d": {"name": "integration_b"}})) == OK,
            "second preset save request sends")
    _server.poll()
    _expect((await _next_message_type("preset_ack", 240)).get("d", {}).get("preset", {}).get("name", "") == "integration_b",
            "second preset is saved")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "retrieve_preset", "seq": 3, "d": {"name": "integration_a"}})) == OK,
            "preset retrieve request sends")
    _server.poll()
    var retrieved: Dictionary = await _next_message_type("preset_ack", 240)
    _expect(retrieved.get("d", {}).get("preset", {}).get("note", "") == "first" and
            retrieved.get("d", {}).get("preset", {}).get("registry_hash", "") == _runtime._gsp_tuning_registry_hash,
            "preset retrieve preserves metadata and registry hash")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "compare_presets", "seq": 4, "d": {"left": "integration_a", "right": "integration_b"}})) == OK,
            "preset comparison request sends")
    _server.poll()
    var comparison: Dictionary = await _next_message_type("preset_ack", 240)
    var comparison_changes: Array = comparison.get("d", {}).get("changes", [])
    _expect(comparison_changes.size() == 1 and comparison_changes[0].get("parameter", "") == "simpleflight.rate_p" and
            comparison_changes[0].get("percentage_status", "") == "finite",
            "preset comparison contains changed parameters only")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "load_preset", "seq": 5, "d": {"name": "integration_a"}})) == OK,
            "preset load request sends")
    _server.poll()
    var load_ack: Dictionary = await _next_message_type("tuning_ack", 240)
    _expect(bool(load_ack.get("d", {}).get("ok", false)) and float(_runtime.native.call("flight_tuning_configuration").get("simpleflight.rate_p", -1.0)) == 0.6,
            "preset load uses the normal atomic native tuning commit")
    _expect(not (await _next_message_type("tuning_commit", 240)).is_empty(), "preset load broadcasts its commit")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "list_presets", "seq": 6, "d": {}})) == OK,
            "preset list request sends")
    _server.poll()
    var listed: Dictionary = await _next_message_type("preset_ack", 240)
    var listed_names: Array = []
    for preset_value in listed.get("d", {}).get("presets", []):
        listed_names.append(String(preset_value.get("name", "")))
    _expect("integration_a" in listed_names and "integration_b" in listed_names,
            "preset list returns only fixed-directory presets")

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


func _next_message_type(message_type: String, attempts: int) -> Dictionary:
    for _attempt in attempts:
        _server.poll()
        _client.poll()
        while _client.get_available_packet_count() > 0:
            var packet := _client.get_packet()
            if not _client.was_string_packet():
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
    _remove_known()
    _client.close()
    if _failures.is_empty():
        print("GSP preset integration: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("GSP preset integration: FAIL")
    quit(1)


func _remove_known() -> void:
    for name in ["integration_a", "integration_b"]:
        var path := GspPresetStore.preset_path(name)
        if not path.is_empty():
            DirAccess.remove_absolute(path)
