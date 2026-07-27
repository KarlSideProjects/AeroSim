extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")

var _runtime: FlightRuntime
var _server: GspServer
var _origin := WebSocketPeer.new()
var _observer := WebSocketPeer.new()
var _failures: Array[String] = []
var _created_names: Array[String] = []
var _name_counter := 0


func _init() -> void:
    await _run()


func _run() -> void:
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

    var baseline_name := _new_name("integration")
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

    await _connect_and_auth(_origin, int(started.port), String(started.token))
    await _connect_and_auth(_observer, int(started.port), String(started.token))
    _expect(not (await _next_message_type(_origin, "hello", 240)).is_empty(), "origin receives hello")
    _expect(not (await _next_message_type(_observer, "hello", 240)).is_empty(), "observer receives hello")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "save_preset", "seq": 1,
            "d": {"name": baseline_name, "note": "first"}})) == OK,
            "preset save request sends")
    _server.poll()
    var saved: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    if bool(saved.get("d", {}).get("ok", false)):
        _remember_created(baseline_name)
    _expect(bool(saved.get("d", {}).get("ok", false)) and
            saved.get("d", {}).get("preset", {}).get("name", "") == baseline_name,
            "preset save returns metadata")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "retrieve_preset", "seq": 2,
            "d": {"name": baseline_name}})) == OK,
            "preset retrieve request sends")
    _server.poll()
    var retrieved: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    _expect(retrieved.get("d", {}).get("preset", {}).get("note", "") == "first" and
            retrieved.get("d", {}).get("preset", {}).get("registry_hash", "") == _runtime._gsp_tuning_registry_hash,
            "preset retrieve preserves metadata and registry hash")

    _runtime.paused = true
    _expect(bool(_runtime.gsp_tuning_request(-1, -1, 1, "simpleflight.rate_p", 1.2).get("ok", false)),
            "integration mutates current through tuning authority")
    _runtime.paused = false
    var before_load: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "load_preset", "seq": 3,
            "d": {"name": baseline_name}})) == OK,
            "active preset load request sends")
    _server.poll()
    var before_boundary: Dictionary = _runtime.native.call("flight_tuning_configuration")
    var early_ack := await _next_message_type(_origin, "tuning_ack", 20)
    _expect(early_ack.is_empty() and float(before_boundary.get("simpleflight.rate_p", -1.0)) == 1.2 and
            int(before_boundary.get("commit_id", -1)) == int(before_load.get("commit_id", -2)),
            "active preset load has no immediate mutation or acknowledgement")

    _runtime._apply_gsp_tuning_requests(9)
    _server.poll()
    var load_ack: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    var origin_commit: Dictionary = await _next_message_type(_origin, "tuning_commit", 240)
    var observer_commit: Dictionary = await _next_message_type(_observer, "tuning_commit", 240)
    var load_data: Dictionary = load_ack.get("d", {})
    var origin_commit_data: Dictionary = origin_commit.get("d", {})
    var observer_commit_data: Dictionary = observer_commit.get("d", {})
    _expect(bool(load_data.get("ok", false)) and int(load_data.get("request_seq", -1)) == 3 and
            String(load_data.get("source", "")) == "preset" and
            int(origin_commit_data.get("commit_id", -1)) > 0 and
            int(origin_commit_data.get("commit_id", -1)) == int(observer_commit_data.get("commit_id", -2)) and
            String(origin_commit_data.get("source", "")) == "preset" and
            String(observer_commit_data.get("source", "")) == "preset" and
            float(_runtime.native.call("flight_tuning_configuration").get("simpleflight.rate_p", -1.0)) == 0.6,
            "active preset load correlates origin ACK and broadcasts one source-tagged commit to both peers")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "list_presets", "seq": 4, "d": {}})) == OK,
            "preset list request sends")
    _server.poll()
    var listed: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    var listed_names: Array = []
    for preset_value in listed.get("d", {}).get("presets", []):
        listed_names.append(String(preset_value.get("name", "")))
    _expect(baseline_name in listed_names, "preset list returns only fixed-directory presets")

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


func _new_name(prefix: String) -> String:
    var store := GspPresetStore.new()
    for _attempt in 100:
        _name_counter += 1
        var candidate := "%s-%d-%d-%d" % [prefix, OS.get_process_id(), Time.get_ticks_usec(), _name_counter]
        if candidate.length() > GspPresetStore.NAME_MAX_LENGTH:
            candidate = candidate.substr(0, GspPresetStore.NAME_MAX_LENGTH)
        var path := GspPresetStore.preset_path(candidate)
        if not path.is_empty() and not FileAccess.file_exists(path):
            return candidate
    return ""


func _remember_created(name: String) -> void:
    if not name.is_empty() and name not in _created_names:
        _created_names.append(name)


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _finish() -> void:
    _server.stop()
    _origin.close()
    _observer.close()
    for name in _created_names:
        var path := GspPresetStore.preset_path(name)
        if not path.is_empty():
            DirAccess.remove_absolute(path)
    if _failures.is_empty():
        print("GSP preset integration: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("GSP preset integration: FAIL")
    quit(1)
