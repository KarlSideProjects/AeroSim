extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")


func _init() -> void:
	var failures: Array[String] = []
	var sample := {
		"publish_count": 17,
		"timestamp_us": 1_250_000,
		"snapshot_hz": 30.0,
		"vehicle_instance": "Drone1",
		"authority": "flight_controller",
		"registry_hash": "registry-fixture",
		"position_ned": {"x_val": 1.0, "y_val": 2.0, "z_val": -3.0},
		"velocity_ned_mps": {"x_val": 4.0, "y_val": 5.0, "z_val": -6.0},
		"attitude_ned": {"w_val": 1.0, "x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
		"rates_frd_rad_s": {"x_val": 0.1, "y_val": 0.2, "z_val": 0.3},
		"units": "SI",
		"world_frame": "NED",
		"body_frame": "FRD",
		"motor_order": ["rear_right", "front_right", "rear_left", "front_left"],
	}

	var payload: Dictionary = GspServer.serialize_telemetry_snapshot(sample, 41, 99)
	_expect(payload.get("sample_seq", -1) == 41, "telemetry sample sequence is independent")
	_expect(not payload.has("seq"), "telemetry does not reuse the reliable envelope sequence")
	_expect(payload.get("tick", -1) == 99, "telemetry carries the runtime tick")
	_expect(payload.get("world_frame", "") == "NED" and payload.get("body_frame", "") == "FRD" and payload.get("units", "") == "SI", "telemetry carries the external coordinate contract")
	_expect(payload.get("motor_order", []) == sample.motor_order, "telemetry preserves the documented motor order")

	var rate := GspServer.validate_telemetry_rate_message(JSON.stringify({"v": 2, "t": "telemetry_rate", "seq": 1, "d": {"rate_hz": 30}}), 0)
	_expect(bool(rate.get("ok", false)) and int(rate.get("rate_hz", -1)) == 30, "30 Hz telemetry rate request is accepted")
	var hidden := GspServer.validate_telemetry_rate_message(JSON.stringify({"v": 2, "t": "telemetry_rate", "seq": 2, "d": {"rate_hz": 0}}), 1)
	_expect(bool(hidden.get("ok", false)) and int(hidden.get("rate_hz", -1)) == 0, "hidden telemetry rate zero is accepted")
	var fresh := GspServer.validate_telemetry_request(JSON.stringify({"v": 2, "t": "telemetry_request", "seq": 3, "d": {"fresh": true}}), 2)
	_expect(bool(fresh.get("ok", false)) and bool(fresh.get("fresh", false)), "fresh telemetry request is accepted")

	var panel_file := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
	var panel := panel_file.get_as_text() if panel_file != null else ""
	for required_text in ["visibilitychange", "telemetry_rate", "telemetry_request", "sample_seq", "canvas"]:
		_expect(panel.to_lower().contains(required_text.to_lower()), "panel contains %s" % required_text)

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
		push_error(message)
