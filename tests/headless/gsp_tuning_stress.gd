extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")

const FRAME_COUNT := 7200
const REQUEST_COUNT := 1500
const REQUESTS_PER_SECOND := 50

var _failures: Array[String] = []
var _server: GspServer
var _runtime: FlightRuntime
var _clients: Array[WebSocketPeer] = []


func _init() -> void:
    await _run()


func _run() -> void:
    _runtime = FlightRuntime.new()
    _runtime.native = ClassDB.instantiate("AeroSimNative")
    _runtime.airsim_session = AirSimSession.new(240)
    _runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    _runtime._airsim_vehicle_name = "DroneA"
    var hardware := HardwareConfig.new()
    _runtime._gsp_tuning_registry = hardware.tuning_registry()
    _runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(_runtime.native != null and hardware.initialize_tuning(_runtime),
            "stress runtime initializes native tuning through the production path")
    if _runtime.native == null:
        _finish()
        return

    _server = GspServer.new()
    root.add_child(_server)
    _server.set_identity_provider(Callable(_runtime, "gsp_identity_snapshot"))
    _server.set_tuning_request_provider(Callable(_runtime, "gsp_tuning_request"))
    _server.set_tuning_result_provider(Callable(_runtime, "gsp_tuning_results"))
    var started: Dictionary = _server.start()
    _server.set_process(false)
    _expect(bool(started.get("ok", false)), "stress server starts")
    if not bool(started.get("ok", false)):
        _finish()
        return

    for _client_index in 2:
        var client := WebSocketPeer.new()
        _clients.append(client)
        await _connect_and_auth(client, int(started.port), String(started.token))
        _expect(not _next_message(client, "hello").is_empty(), "stress client authenticates")

    _runtime._replay_recording_active = true
    var config_json := _runtime._replay_canonical_json(_runtime.native.call("replay_vehicle_config_manifest"))
    var config_hash := String(_runtime.native.call("replay_manifest_hash", config_json))
    var begin: Dictionary = _runtime.native.call(
            "begin_complete_replay_recording", 19, "tuning-stress", "DroneA", config_hash, config_json, 0,
            "DroneB", config_hash, config_json, 0)
    _expect(bool(begin.get("ok", false)), "stress replay recorder starts")
    var atmosphere := {
        "atmosphere": _runtime.native.call("wind_configuration"),
        "atmosphere_air_density_kg_m3": float(_runtime.native.call("body_drag_configuration").get("air_density_kg_m3", 1.225)),
    }
    var environment_result: Dictionary = _runtime.native.call(
            "record_replay_environment", 0, _runtime._replay_canonical_json(atmosphere))
    _expect(bool(environment_result.get("ok", false)), "stress replay records its atmosphere baseline")

    var sent := 0
    var client_sequences := [0, 0]
    var ack_count := 0
    var ack_commit_ids: Array[int] = []
    var commit_ids: Array[int] = []
    var seen_by_client := [{}, {}]
    var duplicate_commit := false
    var multi_origin_coalesced := false
    var max_pending := 0
    var max_completed := 0
    var max_recent := 0
    var max_queue_count := 0
    var max_queue_bytes := 0
    for frame in FRAME_COUNT:
        var wanted := mini(REQUEST_COUNT, int(floor(float(frame + 1) * float(REQUESTS_PER_SECOND) / 240.0)))
        if frame == 0:
            wanted = 2
        while sent < wanted:
            var client_index := sent % 2
            client_sequences[client_index] += 1
            var value := 1.10 if sent == 0 else 1.11 if sent == 1 else 1.75 if sent == REQUEST_COUNT - 1 else 0.6 + float(sent) / 2000.0
            var client: WebSocketPeer = _clients[client_index]
            var send_result := client.send_text(JSON.stringify({
                "v": 2,
                "t": "set_tuning",
                "seq": client_sequences[client_index],
                "d": {"parameter": "simpleflight.rate_p", "value": value},
            }))
            _expect(send_result == OK, "stress request sends through an authenticated client")
            sent += 1

        _server.poll()
        for client in _clients:
            client.poll()
        _runtime._physics_process(1.0 / 240.0)
        _server.poll()
        for client_index in _clients.size():
            var client: WebSocketPeer = _clients[client_index]
            client.poll()
            for message in _drain_messages(client):
                var message_type := String(message.get("t", ""))
                var data: Dictionary = message.get("d", {})
                if message_type == "tuning_ack":
                    ack_count += 1
                    if bool(data.get("coalesced", false)):
                        multi_origin_coalesced = true
                    var ack_commit_id := int(data.get("commit_id", 0))
                    if ack_commit_id > 0 and ack_commit_id not in ack_commit_ids:
                        ack_commit_ids.append(ack_commit_id)
                elif message_type == "tuning_commit":
                    var commit_id := int(data.get("commit_id", 0))
                    if commit_id in seen_by_client[client_index]:
                        duplicate_commit = true
                    seen_by_client[client_index][commit_id] = true
                    if commit_id not in commit_ids:
                        commit_ids.append(commit_id)
        max_pending = maxi(max_pending, _runtime._gsp_tuning_pending.size())
        max_completed = maxi(max_completed, _runtime._gsp_tuning_completed.size())
        max_recent = maxi(max_recent, _runtime._gsp_tuning_recent_results.size())
        for diagnostic in _server.get_peer_transport_diagnostics():
            max_queue_count = maxi(max_queue_count, int(diagnostic.get("reliable_queue_count", 0)))
            max_queue_bytes = maxi(max_queue_bytes, int(diagnostic.get("reliable_queue_bytes", 0)))
        await process_frame

    for _attempt in 120:
        _server.poll()
        for client_index in _clients.size():
            var client: WebSocketPeer = _clients[client_index]
            client.poll()
            for message in _drain_messages(client):
                if String(message.get("t", "")) != "tuning_commit":
                    continue
                var commit_id := int(message.get("d", {}).get("commit_id", 0))
                if commit_id in seen_by_client[client_index]:
                    duplicate_commit = true
                seen_by_client[client_index][commit_id] = true
                if commit_id not in commit_ids:
                    commit_ids.append(commit_id)
        await process_frame

    var finish: Dictionary = _runtime.native.call("finish_complete_replay_recording", 30_000_000, "tuning-stress")
    _runtime._replay_recording_active = false
    var serialized := String(finish.get("serialized", ""))
    var active: Dictionary = _runtime.native.call("flight_tuning_configuration")
    var diagnostics: Dictionary = _runtime.native.call("flight_control_diagnostics")
    _expect(sent == REQUEST_COUNT and ack_count == REQUEST_COUNT, "stress receives one ACK for every request")
    _expect(float(active.get("simpleflight.rate_p", 0.0)) == 1.75,
            "real server stress commits the final drag value")
    _expect(is_finite(float(active.get("simpleflight.rate_p", NAN))) and
            is_finite(float(diagnostics.get("angular_velocity_x_rad_s", NAN))) and
            is_finite(float(diagnostics.get("angular_velocity_y_rad_s", NAN))) and
            is_finite(float(diagnostics.get("angular_velocity_z_rad_s", NAN))),
            "real server stress leaves finite native state")
    _expect(max_pending <= 2 and max_completed <= 2 and max_recent <= 16 and
            max_queue_count < GspServer.MAX_RELIABLE_MESSAGES and max_queue_bytes < GspServer.MAX_RELIABLE_BYTES and
            _server.reliable_overflow_count == 0 and not duplicate_commit and multi_origin_coalesced,
            "real server stress keeps queues, results, replay correlation, and broadcasts bounded")
    var replay_event_count := serialized.count("\"type\":\"tuning\"")
    _expect(bool(finish.get("ok", false)) and replay_event_count == ack_commit_ids.size() and
            commit_ids.size() == ack_commit_ids.size() and replay_event_count <= REQUEST_COUNT,
            "real server stress records every actual commit without replay growth (%d/%d/%d)" % [
                replay_event_count, ack_commit_ids.size(), commit_ids.size()])

    for client in _clients:
        client.close()
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
    for _attempt in 240:
        _server.poll()
        client.poll()
        if client.get_available_packet_count() > 0:
            return
        await process_frame


func _next_message(client: WebSocketPeer, message_type: String) -> Dictionary:
    while client.get_available_packet_count() > 0:
        var packet := client.get_packet()
        if not client.was_string_packet():
            continue
        var parsed = JSON.parse_string(packet.get_string_from_utf8())
        if typeof(parsed) == TYPE_DICTIONARY and String(parsed.get("t", "")) == message_type:
            return parsed
    return {}


func _drain_messages(client: WebSocketPeer) -> Array:
    var messages: Array = []
    while client.get_available_packet_count() > 0:
        var packet := client.get_packet()
        if not client.was_string_packet():
            continue
        var parsed = JSON.parse_string(packet.get_string_from_utf8())
        if typeof(parsed) == TYPE_DICTIONARY:
            messages.append(parsed)
    return messages


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _finish() -> void:
    if _failures.is_empty():
        print("GSP tuning stress: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("GSP tuning stress: FAIL")
    quit(1)
