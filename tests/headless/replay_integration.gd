extends SceneTree

const ReplayIntegrationRunner = preload("res://common/flight/replay_integration_runner.gd")


func _initialize() -> void:
    var result: Dictionary = ReplayIntegrationRunner.new().run()
    if bool(result.get("ok", false)):
        _pass()
    else:
        _fail(String(result.get("error", "unknown")))


func _pass() -> void:
    print("complete-session replay integration: PASS")
    quit(0)


func _fail(message: String) -> void:
    push_error(message)
    quit(1)
