extends GutTest

## AirSim addresses altitude as NED z relative to the spawn origin, which is the
## frame `_airsim_task_complete` and the landed-state reporting already use.
## These tests pin the vertical velocity commands to that same frame, so a map
## whose spawn sits well above world height zero still climbs on takeoff instead
## of being commanded into a descent it can never complete.

const FlightRuntime = preload("res://common/flight/flight_runtime.gd")

const HIGH_SPAWN_HEIGHT_M := 80.3
const HOVER_THROTTLE := 0.5


class FakeBody extends RefCounted:
    var global_position := Vector3.ZERO
    var linear_velocity := Vector3.ZERO
    var angular_velocity := Vector3.ZERO
    var global_transform := Transform3D.IDENTITY
    var freeze := false
    var sleeping := false


## Only the map goes into the scene tree. `_spawn_position()` reads the spawn
## marker's `global_position`, which Godot resolves only for nodes in the tree,
## while the runtime itself stays detached so `_ready` never starts the RPC
## listener or the native runtime for what is a pure command-frame test.
func _runtime_with_spawn(spawn_height_m: float) -> Node3D:
    var runtime: Node3D = FlightRuntime.new()
    autofree(runtime)
    var map := Node3D.new()
    map.name = "LoadedMap"
    add_child_autofree(map)
    var spawn := Marker3D.new()
    spawn.name = "SpawnNorth"
    spawn.position = Vector3(520.0, spawn_height_m, -790.0)
    map.add_child(spawn)
    runtime.loaded_map = map
    var spawn_names: Array[String] = ["SpawnNorth"]
    runtime.loaded_spawn_names = spawn_names
    runtime.current_spawn_index = 0
    return runtime


func _body_at(spawn_height_m: float, altitude_above_spawn_m: float) -> FakeBody:
    var body := FakeBody.new()
    body.global_position = Vector3(520.0, spawn_height_m + altitude_above_spawn_m, -790.0)
    return body


func _throttle(runtime: Node3D, method: String, args: Array, body: FakeBody) -> float:
    var context := {"command_state": {"method": method, "args": args}}
    var controls: Dictionary = runtime.call("_airsim_secondary_controls", context, body)
    return float(controls["throttle"])


func test_altitude_above_origin_is_measured_from_the_spawn_not_world_zero() -> void:
    var runtime := _runtime_with_spawn(HIGH_SPAWN_HEIGHT_M)
    assert_almost_eq(float(runtime.call("_airsim_altitude_above_origin", _body_at(HIGH_SPAWN_HEIGHT_M, 0.0))), 0.0, 0.0001)
    assert_almost_eq(float(runtime.call("_airsim_altitude_above_origin", _body_at(HIGH_SPAWN_HEIGHT_M, 4.5))), 4.5, 0.0001)
    assert_almost_eq(float(runtime.call("_airsim_altitude_above_origin", _body_at(HIGH_SPAWN_HEIGHT_M, -1.25))), -1.25, 0.0001)


func test_takeoff_climbs_from_a_spawn_high_above_world_zero() -> void:
    var runtime := _runtime_with_spawn(HIGH_SPAWN_HEIGHT_M)
    assert_gt(_throttle(runtime, "takeoff", [], _body_at(HIGH_SPAWN_HEIGHT_M, 0.0)), HOVER_THROTTLE,
        "takeoff from an elevated spawn must command a climb, not a descent")


func test_takeoff_levels_off_at_the_commanded_altitude_above_the_spawn() -> void:
    var runtime := _runtime_with_spawn(HIGH_SPAWN_HEIGHT_M)
    var target: float = FlightRuntime.AIRSIM_TAKEOFF_ALTITUDE_M
    assert_almost_eq(_throttle(runtime, "takeoff", [], _body_at(HIGH_SPAWN_HEIGHT_M, target)), HOVER_THROTTLE, 0.0001)
    assert_lt(_throttle(runtime, "takeoff", [], _body_at(HIGH_SPAWN_HEIGHT_M, target + 2.0)), HOVER_THROTTLE)


func test_land_descends_toward_the_spawn_height_not_world_zero() -> void:
    var runtime := _runtime_with_spawn(HIGH_SPAWN_HEIGHT_M)
    assert_lt(_throttle(runtime, "land", [], _body_at(HIGH_SPAWN_HEIGHT_M, 3.0)), HOVER_THROTTLE)
    assert_almost_eq(_throttle(runtime, "land", [], _body_at(HIGH_SPAWN_HEIGHT_M, 0.0)), HOVER_THROTTLE, 0.0001)


func test_move_by_velocity_z_targets_ned_altitude_above_the_spawn() -> void:
    var runtime := _runtime_with_spawn(HIGH_SPAWN_HEIGHT_M)
    # NED z of -5 is five metres above the spawn origin.
    var args := [0.0, 0.0, -5.0, 1.0, 0, null]
    assert_gt(_throttle(runtime, "moveByVelocityZ", args, _body_at(HIGH_SPAWN_HEIGHT_M, 1.0)), HOVER_THROTTLE)
    assert_almost_eq(_throttle(runtime, "moveByVelocityZ", args, _body_at(HIGH_SPAWN_HEIGHT_M, 5.0)), HOVER_THROTTLE, 0.0001)
    assert_lt(_throttle(runtime, "moveByVelocityZ", args, _body_at(HIGH_SPAWN_HEIGHT_M, 9.0)), HOVER_THROTTLE)


func test_vertical_commands_are_unchanged_for_a_spawn_at_world_zero() -> void:
    var runtime := _runtime_with_spawn(0.0)
    assert_almost_eq(_throttle(runtime, "takeoff", [], _body_at(0.0, 0.0)), 0.95, 0.0001,
        "the world-zero spawn behaviour must be preserved")
    assert_almost_eq(_throttle(runtime, "land", [], _body_at(0.0, 3.0)), 0.05, 0.0001)
