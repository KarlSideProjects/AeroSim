extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const FRAME_COUNT := 30
const WARMUP_FRAMES := 30
const MAX_SLOWDOWN_RATIO := 1.5


class ProbeLicenseProvider:
    extends Node

    func get_snapshot() -> Dictionary:
        return {"ok": true, "status": "online_valid", "last_online_result": "locale_flight_probe"}


func _initialize() -> void:
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    _run()


func _run() -> void:
    var runtime := SmokeScene.instantiate()
    root.add_child(runtime)
    await _settle(30)
    _install_valid_license(runtime)
    runtime.quick_fly()
    if not await _wait_for_one_of(runtime, ["fallback_prompt", "controller_confirmation"]):
        _fail("Quick Fly did not reach input confirmation: %s" % runtime.screen)
        return
    if runtime.screen == "controller_confirmation":
        runtime.use_keyboard_fallback()
    runtime.accept_fallback()
    if not await _wait_for_screen(runtime, "preflight"):
        _fail("keyboard fallback did not reach preflight: %s" % runtime.screen)
        return
    runtime.arm_and_takeoff()
    if not await _wait_for_screen(runtime, "flight"):
        _fail("takeoff did not reach flight: %s" % runtime.screen)
        return
    var en := await _measure(runtime, "en")
    var zh_tw := await _measure(runtime, "zh_TW")
    var en_after := await _measure(runtime, "en")
    var zh_tw_after := await _measure(runtime, "zh_TW")
    var result := {
        "en": en,
        "zh_TW": zh_tw,
        "en_after": en_after,
        "zh_TW_after": zh_tw_after,
        "slowdown_ratio": zh_tw.p95_frame_ms / maxf(en.p95_frame_ms, 0.001),
        "repeat_slowdown_ratio": zh_tw_after.p95_frame_ms / maxf(en_after.p95_frame_ms, 0.001),
    }
    print("LOCALE_FLIGHT_PROBE=" + JSON.stringify(result))
    if float(result.slowdown_ratio) > MAX_SLOWDOWN_RATIO or float(result.repeat_slowdown_ratio) > MAX_SLOWDOWN_RATIO:
        _fail("zh_TW p95 frame time exceeds en by %.2fx and %.2fx" % [result.slowdown_ratio, result.repeat_slowdown_ratio])
        return
    quit(0)


func _install_valid_license(runtime: Node) -> void:
    if runtime.license_provider != null:
        runtime.remove_child(runtime.license_provider)
        runtime.license_provider.queue_free()
    runtime.license_provider = ProbeLicenseProvider.new()
    runtime.add_child(runtime.license_provider)
    runtime.show_main_menu()


func _wait_for_screen(runtime: Node, expected: String) -> bool:
    for _frame in 240:
        if runtime.screen == expected:
            return true
        await process_frame
    return false


func _wait_for_one_of(runtime: Node, expected: Array[String]) -> bool:
    for _frame in 240:
        if runtime.screen in expected:
            return true
        await process_frame
    return false


func _settle(frames: int) -> void:
    for _frame in frames:
        await process_frame


func _measure(runtime: Node, locale: String) -> Dictionary:
    if not runtime.set_locale(locale):
        return {"p95_frame_ms": INF, "error": "locale switch failed"}
    await _settle(WARMUP_FRAMES)
    var samples: Array[float] = []
    var previous_us := Time.get_ticks_usec()
    for _frame in FRAME_COUNT:
        await process_frame
        var now_us := Time.get_ticks_usec()
        samples.append(float(now_us - previous_us) / 1000.0)
        previous_us = now_us
    samples.sort()
    return {
        "median_frame_ms": samples[samples.size() / 2],
        "p95_frame_ms": samples[int(floor(float(samples.size() - 1) * 0.95))],
    }


func _fail(message: String) -> void:
    push_error(message)
    quit(1)
