extends SceneTree

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")


func _init() -> void:
	var failures: Array[String] = []
	if GspServer.PROTOCOL_VERSION != 2:
		failures.append("GSP protocol version must be integer 2")
	if GspServer.PORT_RANGE != [8765, 8766, 8767, 8768, 8769]:
		failures.append("GSP must try ports 8765 through 8769")
	var server_source_file := FileAccess.open("res://common/gsp/gsp_server.gd", FileAccess.READ)
	if server_source_file == null or not server_source_file.get_as_text().contains("MAX_UNAUTHENTICATED_PEERS"):
		failures.append("GSP must bound the separate open-unauthenticated peer set")
	if not GspServer.validate_bind_address("127.0.0.1").ok or GspServer.validate_bind_address("0.0.0.0").ok:
		failures.append("GSP must reject non-loopback bind addresses")

	var first_token := GspServer.generate_token()
	var second_token := GspServer.generate_token()
	if first_token.length() != 32 or second_token.length() != 32:
		failures.append("GSP tokens must contain 128 bits encoded as 32 hex characters")
	if first_token == second_token:
		failures.append("GSP token generation must be fresh")

	var url := GspLauncher.panel_url("file:///tmp/panel.html", 8765, first_token)
	if url != "file:///tmp/panel.html#port=8765&token=%s" % first_token:
		failures.append("GSP launch URL must carry the selected port and token in its fragment")

	var auth := GspServer.validate_auth_message(
		JSON.stringify({"v": 2, "t": "auth", "seq": 1, "d": {"token": first_token}}),
		first_token)
	if not bool(auth.get("ok", false)):
		failures.append("valid auth envelope must be accepted: %s" % auth)
	var wrong_token := GspServer.validate_auth_message(
		JSON.stringify({"v": 2, "t": "auth", "seq": 2, "d": {"token": second_token}}),
		first_token)
	if bool(wrong_token.get("ok", true)):
		failures.append("wrong auth token must be rejected")
	var wrong_version := GspServer.validate_auth_message(
		JSON.stringify({"v": 1, "t": "auth", "seq": 3, "d": {"token": first_token}}),
		first_token)
	if bool(wrong_version.get("ok", true)):
		failures.append("wrong protocol version must be rejected")
	var malformed := GspServer.validate_auth_message("{\"v\":2,\"t\":\"hello\",\"seq\":4,\"d\":{}}", first_token)
	if bool(malformed.get("ok", true)):
		failures.append("non-auth first message must be rejected")
	var oversized := GspServer.validate_auth_message("x".repeat(GspServer.MAX_MESSAGE_BYTES + 1), first_token)
	if bool(oversized.get("ok", true)):
		failures.append("oversized auth message must be rejected")
	var ping := GspServer.validate_ping_message(JSON.stringify({"v": 2, "t": "ping", "seq": 2, "d": {"request": "fixture"}}))
	if not bool(ping.get("ok", false)):
		failures.append("valid v2 ping envelope must be accepted")
	var panel_file := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
	if panel_file == null or not panel_file.get_as_text().contains("new WebSocket") or not panel_file.get_as_text().contains("t: \"auth\""):
		failures.append("panel must establish the dependency-free authenticated WebSocket session")

	if failures.is_empty():
		print("GSP transport contract: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("GSP transport contract: FAIL")
		quit(1)
