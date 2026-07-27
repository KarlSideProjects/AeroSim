extends SceneTree

const GspServer = preload("res://common/gsp/gsp_server.gd")


func _init() -> void:
    var failures: Array[String] = []
    if GspServer.MAX_RELIABLE_MESSAGE_BYTES <= 0 or GspServer.MAX_RELIABLE_MESSAGE_BYTES > GspServer.MAX_RELIABLE_BYTES:
        failures.append("reliable message must fit the reliable byte bound")
    if GspServer.TELEMETRY_SUPPRESSION_THRESHOLD_BYTES >= GspServer.MAX_RELIABLE_BYTES:
        failures.append("telemetry suppression must precede the reliable byte bound")
    if GspServer.MAX_RELIABLE_BYTES >= GspServer.HARD_CLOSE_THRESHOLD_BYTES:
        failures.append("reliable byte bound must remain reachable below hard close")
    if GspServer.HARD_CLOSE_THRESHOLD_BYTES + GspServer.MAX_OUTBOUND_MESSAGE_BYTES > GspServer.NATIVE_OUTBOUND_CAPACITY_BYTES:
        failures.append("native capacity must cover hard-close headroom")
    if GspServer.MAX_NATIVE_QUEUED_PACKETS <= GspServer.MAX_RELIABLE_MESSAGES:
        failures.append("native packet capacity must exceed reliable application count")
    if not GspServer.is_telemetry_suppressed(GspServer.TELEMETRY_SUPPRESSION_THRESHOLD_BYTES):
        failures.append("telemetry pressure must suppress at its threshold")
    if GspServer.is_telemetry_suppressed(GspServer.TELEMETRY_SUPPRESSION_THRESHOLD_BYTES - 1):
        failures.append("telemetry must remain available below its threshold")
    if not GspServer.is_hard_close_pressure(GspServer.HARD_CLOSE_THRESHOLD_BYTES):
        failures.append("hard pressure must close at its threshold")
    if GspServer.is_hard_close_pressure(GspServer.HARD_CLOSE_THRESHOLD_BYTES - 1):
        failures.append("hard pressure must remain open below its threshold")
    if GspServer.can_admit_reliable(GspServer.MAX_RELIABLE_MESSAGES, 0, 1):
        failures.append("reliable admission must reject the application packet-count bound")
    if GspServer.can_admit_reliable(0, GspServer.MAX_RELIABLE_BYTES, 1):
        failures.append("reliable admission must reject the application byte bound")
    if not GspServer.can_admit_reliable(0, 0, 1):
        failures.append("reliable admission must accept a bounded application message")

    var overflow := GspServer.overflow_error_envelope(7)
    if overflow.get("t", "") != "error" or overflow.get("d", {}).get("code", "") != "overflow":
        failures.append("overflow must use the bounded error{code:overflow} envelope")

    var source_file := FileAccess.open("res://common/gsp/gsp_server.gd", FileAccess.READ)
    var source := source_file.get_as_text() if source_file != null else ""
    if not source.contains("overflow_error_pending"):
        failures.append("overflow state must have a persistent overflow-specific pending flag")
    var failure_start := source.find("func _record_reliable_failure")
    var failure_end := source.find("func _attempt_overflow_error", failure_start)
    if failure_start < 0 or failure_end < 0 or source.substr(failure_start, failure_end - failure_start).contains("_attempt_overflow_error"):
        failures.append("recording overflow must defer the attempt to the closing pump")
    var overflow_start := source.find("func _attempt_overflow_error")
    var overflow_end := source.find("func _record_hard_close", overflow_start)
    if overflow_start < 0 or overflow_end < 0 or source.substr(overflow_start, overflow_end - overflow_start).contains("_flush_reliable"):
        failures.append("overflow attempt must not recursively drain reliable FIFO")
    if overflow_start < 0 or overflow_end < 0 or not source.substr(overflow_start, overflow_end - overflow_start).contains("_check_native_outbound_pressure"):
        failures.append("overflow attempt must check native hard pressure before direct send")

    if failures.is_empty():
        print("GSP backpressure contract: PASS")
        quit(0)
    else:
        for failure in failures:
            push_error(failure)
        print("GSP backpressure contract: FAIL")
        quit(1)
