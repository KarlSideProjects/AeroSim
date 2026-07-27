extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")
var failures: Array[String] = []


func _init() -> void:
	var sample := {
		"publish_count": 17,
		"timestamp_us": 1_250_000,
		"snapshot_hz": 30.0,
		"vehicle_instance": "Drone1",
		"authority": "flight_controller",
		"registry_hash": "registry-fixture",
		"pos_ned": {"x_val": 1.0, "y_val": 2.0, "z_val": -3.0},
		"vel_ned": {"x_val": 4.0, "y_val": 5.0, "z_val": -6.0},
		"att_euler_deg": {"roll": 1.0, "pitch": 2.0, "yaw": 3.0},
		"gyro_body": {"x_val": 0.1, "y_val": 0.2, "z_val": 0.3},
		"units": "SI",
		"world_frame": "NED",
		"body_frame": "FRD",
		"motor_order": ["rear_right", "front_right", "rear_left", "front_left"],
		"rpm": [1000.0, 2000.0, 3000.0, 4000.0],
	}

	var payload: Dictionary = GspServer.serialize_telemetry_snapshot(sample, 41, 99, 7)
	var data: Dictionary = payload.get("d", {})
	_expect(payload.get("v", -1) == 2 and payload.get("t", "") == "telemetry", "telemetry uses the v2 envelope")
	_expect(payload.get("seq", -1) == 7 and payload.get("tick", -1) == 99 and typeof(data) == TYPE_DICTIONARY, "telemetry carries sender sequence, top-level tick, and data")
	_expect(data.get("sample_seq", -1) == 41, "telemetry sample sequence is independent inside data")
	_expect(not payload.has("sample_seq") and not payload.has("pos_ned"), "telemetry fields are not flattened")
	_expect(data.get("world_frame", "") == "NED" and data.get("body_frame", "") == "FRD" and data.get("units", "") == "SI", "telemetry carries the external coordinate contract")
	_expect(data.get("motor_order", []) == sample.motor_order and data.get("rpm", []) == sample.rpm, "telemetry preserves Betaflight motor data")
	var existing_slot := {"d": {"sample_seq": 40, "pos_ned": {"x_val": 40.0}}}
	var newest_slot := {"d": {"sample_seq": 41, "pos_ned": {"x_val": 41.0}}}
	var replaced_slot: Dictionary = GspServer.latest_wins_telemetry_slot(existing_slot, newest_slot)
	_expect(int(replaced_slot.get("d", {}).get("sample_seq", 0)) == 41, "newer telemetry replaces an existing lossy slot")

	var rate := GspServer.validate_set_telemetry_message(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 1, "d": {"hz": 30, "extra": false}}), 0)
	_expect(bool(rate.get("ok", false)) and int(rate.get("hz", -1)) == 30, "30 Hz telemetry request is accepted")
	var hidden := GspServer.validate_set_telemetry_message(JSON.stringify({"v": 2, "t": "set_telemetry", "seq": 2, "d": {"hz": 0, "extra": false}}), 1)
	_expect(bool(hidden.get("ok", false)) and int(hidden.get("hz", -1)) == 0, "hidden telemetry rate zero is accepted")
	var fresh := GspServer.validate_request_snapshot_message(JSON.stringify({"v": 2, "t": "request_snapshot", "seq": 3, "d": {}}), 2)
	_expect(bool(fresh.get("ok", false)), "fresh snapshot request is accepted")
	var legacy := GspServer.validate_set_telemetry_message(JSON.stringify({"v": 2, "t": "telemetry_rate", "seq": 4, "d": {"rate_hz": 30}}), 3)
	_expect(not bool(legacy.get("ok", false)), "legacy telemetry control name is rejected")

	var panel_file := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
	var panel := panel_file.get_as_text() if panel_file != null else ""
	for required_text in ["visibilitychange", "set_telemetry", "request_snapshot", "sample_seq", "canvas", "ping", "pong", "WebSocket RTT"]:
		_expect(panel.to_lower().contains(required_text.to_lower()), "panel contains %s" % required_text)
	_expect(not panel.contains("telemetry_rate") and not panel.contains("telemetry_request"), "panel does not use legacy telemetry controls")
	_expect(not panel.contains("sample.sent_at_unix_ms"), "sample age is not mislabeled as WebSocket RTT")

	if failures.is_empty():
		print("GSP telemetry contract: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("GSP telemetry contract: FAIL")
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
