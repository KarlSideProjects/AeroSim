extends GutTest

const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")


class FakeGspLauncher extends Node:
    var available := true
    var open_calls := 0
    var copy_calls := 0

    func is_panel_ready() -> bool:
        return available

    func request_panel_open() -> Dictionary:
        open_calls += 1
        available = true
        return {"ok": true}

    func copy_panel_url() -> Dictionary:
        copy_calls += 1
        available = true
        return {"ok": true}


func _runtime_with_gsp(ready: bool) -> Dictionary:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var launcher := FakeGspLauncher.new()
    launcher.name = "GspLauncher"
    launcher.available = ready
    runtime.add_child(launcher)
    var hud := CanvasLayer.new()
    hud.name = "FlightHud"
    runtime.flight_hud_layer = hud
    runtime.add_child(hud)
    runtime._build_pause_panel()
    return {"runtime": runtime, "launcher": launcher}


func test_ready_gsp_exposes_pause_actions_without_rendering_the_url() -> void:
    var fixture := _runtime_with_gsp(true)
    var runtime: Node = fixture.runtime
    var launcher: FakeGspLauncher = fixture.launcher
    var open: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/OpenGspPanel")
    var copy: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/CopyGspUrl")
    var status: Label = runtime.get_node_or_null("FlightHud/PausePanel/Rows/GspPanelStatus")

    assert_not_null(open)
    assert_not_null(copy)
    assert_not_null(status)
    if open != null:
        open.pressed.emit()
    if copy != null:
        copy.pressed.emit()
    assert_eq(launcher.open_calls, 1)
    assert_eq(launcher.copy_calls, 1)
    assert_false(status.text.contains("file://"))
    assert_false(status.text.contains("token="))


func test_unready_gsp_exposes_actions_that_start_the_panel() -> void:
    var fixture := _runtime_with_gsp(false)
    var runtime: Node = fixture.runtime
    var launcher: FakeGspLauncher = fixture.launcher
    var open: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/OpenGspPanel")
    var copy: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/CopyGspUrl")

    assert_not_null(open)
    assert_not_null(copy)
    if open != null:
        open.pressed.emit()
    if copy != null:
        copy.pressed.emit()
    assert_eq(launcher.open_calls, 1)
    assert_eq(launcher.copy_calls, 1)


func test_demo_panel_split_reserves_the_upper_four_fifths_for_the_game() -> void:
    var split := GspLauncher.demo_panel_split(Vector2i(100, 50), Vector2i(1920, 900))

    assert_eq(split.game_size, Vector2i(1920, 720))
    assert_eq(split.panel_position, Vector2i(100, 770))
    assert_eq(split.panel_size, Vector2i(1920, 180))
