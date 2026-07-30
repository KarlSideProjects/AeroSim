extends SceneTree

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")

class LauncherHarness extends GspLauncher:
    var open_invoked := false

    func get_display_name() -> String:
        return "Wayland"

    func open_panel(_url: String) -> bool:
        open_invoked = true
        return true


class TelemetryParent extends Node:
    var hardware_configuration: Dictionary = {}

    func gsp_telemetry_snapshot() -> Dictionary:
        # The browser harness uses a real shipped preset so the production
        # renderer builds its configuration-derived model.
        return {
            "publish_count": 1,
            "tick": 1,
            "authority": "flight_controller",
            "armed": false,
            "motor_order": ["rear_right", "front_right", "rear_left", "front_left"],
            "motors": [
                {"thrust_newtons": 2.0, "current_a": 1.0, "saturated": false},
                {"thrust_newtons": 2.0, "current_a": 1.0, "saturated": false},
                {"thrust_newtons": 2.0, "current_a": 1.0, "saturated": false},
                {"thrust_newtons": 2.0, "current_a": 1.0, "saturated": false},
            ],
            "rpm": [1000.0, 1000.0, 1000.0, 1000.0],
            "hardware_configuration": hardware_configuration,
            "hardware_power_model": {
                "max_total_thrust_newtons": 40.0,
                "max_total_current_a": 40.0,
                "max_motor_rpm": 15000.0,
            },
        }


var _stop_path := ""
var _launcher: LauncherHarness
var _telemetry_parent: TelemetryParent


func _init() -> void:
    var args := OS.get_cmdline_user_args()
    _stop_path = _argument(args, "--stop-file")
    if _stop_path.is_empty():
        push_error("GSP launcher harness requires --stop-file")
        quit(2)
        return
    var hardware := HardwareConfig.new()
    var hardware_configuration: Dictionary = hardware.load_preset("res://config/drones/5_inch_6s.json")
    if not hardware.last_ok:
        push_error(hardware.last_error)
        quit(1)
        return
    _telemetry_parent = TelemetryParent.new()
    _telemetry_parent.hardware_configuration = hardware_configuration
    get_root().add_child(_telemetry_parent)
    _launcher = LauncherHarness.new()
    _telemetry_parent.add_child(_launcher)
    var result := _launcher.launch({
        "enabled": true,
        "open": true,
    })
    if not bool(result.get("ok", false)):
        push_error(String(result.get("error", "GSP launcher failed")))
        quit(1)
        return
    if not _launcher.open_invoked:
        push_error("GSP launcher did not invoke the requested panel opener")
        quit(1)


func _process(_delta: float) -> bool:
    if FileAccess.file_exists(_stop_path):
        DirAccess.remove_absolute(_stop_path)
        _telemetry_parent.free()
        quit(0)
    return false


func _argument(args: Array[String], name: String) -> String:
    var index := args.find(name)
    return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""
