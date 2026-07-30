#!/usr/bin/env python3
"""Execute one real PX4 hover wind step through the live GSP WebSocket."""

from __future__ import annotations

import argparse
import json
import math
import threading
import time
from pathlib import Path
from typing import Any, Callable

PX4_REVISION = "1dacb4cdef2d7145754fc788fa8dc482eed74b40"
WIND_FROM_DEG = 270.0
WIND_SPEED_MPS = 7.0
# The smoke scene starts Drone1 one metre north of RuntimeWall.  Keep this
# qualification route on the clear, negative-north side of the wall: the
# mission must exercise PX4 takeoff, position hold, and the wind step without
# treating an intentional obstacle collision as a flight-control failure.
QUALIFICATION_TAKEOFF_NED = (0.0, 0.0, -3.0)
TARGET_NED = (-2.0, -1.0, -3.0)
# RuntimeWall is a 0.2 m-thick 2 m cube at the smoke-scene origin.  These
# bounds include the 0.1 m drone collision radius, expressed relative to the
# qualification spawn point in local NED coordinates.
RUNTIME_WALL_NED_MIN = (0.8, -1.1, -1.1)
RUNTIME_WALL_NED_MAX = (1.2, 1.1, 1.1)
QUALIFICATION_DRONE1_SPAWN_WORLD = (-1.0, 0.0, 0.0)
QUALIFICATION_DRONE2_SPAWN_WORLD = (-1.0, 0.0, 2.0)
QUALIFICATION_DRONE2_CLEARANCE_M = 0.2
POSITION_RMS_LIMIT_M = 0.75
POSITION_MAX_LIMIT_M = 1.25
ASYNC_COMMAND_TIMEOUT_SECONDS = 45.0


def segment_intersects_runtime_wall(start: tuple[float, float, float], end: tuple[float, float, float]) -> bool:
    """Return whether a local-NED segment enters RuntimeWall's safe envelope."""
    entry = 0.0
    exit = 1.0
    for axis in range(3):
        delta = end[axis] - start[axis]
        lower = RUNTIME_WALL_NED_MIN[axis]
        upper = RUNTIME_WALL_NED_MAX[axis]
        if abs(delta) < 1e-9:
            if start[axis] < lower or start[axis] > upper:
                return False
            continue
        first = (lower - start[axis]) / delta
        last = (upper - start[axis]) / delta
        entry = max(entry, min(first, last))
        exit = min(exit, max(first, last))
        if entry > exit:
            return False
    return True


def qualification_corridor_is_clear() -> bool:
    """Ensure the test-only command route stays out of RuntimeWall.

    PX4 can accept the target command before the bridge has observed altitude
    change, so validate the conservative spawn-to-target fallback as well as
    the nominal takeoff-to-target leg.
    """
    spawn = (0.0, 0.0, 0.0)
    return (
        not segment_intersects_runtime_wall(spawn, QUALIFICATION_TAKEOFF_NED)
        and not segment_intersects_runtime_wall(QUALIFICATION_TAKEOFF_NED, TARGET_NED)
        and not segment_intersects_runtime_wall(spawn, TARGET_NED)
        and qualification_route_clears_drone2()
    )


def qualification_route_clears_drone2() -> bool:
    """Keep the test-only parked Drone2 out of Drone1's takeoff/target path."""
    spawn = QUALIFICATION_DRONE1_SPAWN_WORLD
    takeoff = (spawn[0], spawn[1] - QUALIFICATION_TAKEOFF_NED[2], spawn[2])
    target = (spawn[0] + TARGET_NED[0], spawn[1] - TARGET_NED[2], spawn[2] + TARGET_NED[1])
    return (
        _point_to_segment_distance(QUALIFICATION_DRONE2_SPAWN_WORLD, spawn, takeoff) > QUALIFICATION_DRONE2_CLEARANCE_M
        and _point_to_segment_distance(QUALIFICATION_DRONE2_SPAWN_WORLD, takeoff, target) > QUALIFICATION_DRONE2_CLEARANCE_M
    )


def _point_to_segment_distance(point: tuple[float, float, float], start: tuple[float, float, float], end: tuple[float, float, float]) -> float:
    direction = tuple(end[axis] - start[axis] for axis in range(3))
    length_squared = sum(component * component for component in direction)
    if length_squared == 0.0:
        return math.dist(point, start)
    offset = tuple(point[axis] - start[axis] for axis in range(3))
    fraction = max(0.0, min(1.0, sum(offset[axis] * direction[axis] for axis in range(3)) / length_squared))
    closest = tuple(start[axis] + fraction * direction[axis] for axis in range(3))
    return math.dist(point, closest)


def wait_for_async_command(command: Callable[[], Any], stage: str, timeout_seconds: float = ASYNC_COMMAND_TIMEOUT_SECONDS) -> None:
    """Bound AirSim Future creation and join without changing the flight command."""
    completed = threading.Event()
    failure: list[BaseException] = []

    def join() -> None:
        try:
            command().join()
        except BaseException as error:
            failure.append(error)
        finally:
            completed.set()

    threading.Thread(target=join, daemon=True).start()
    if not completed.wait(timeout_seconds):
        raise TimeoutError(f"{stage} timed out after {timeout_seconds:.1f} seconds")
    if failure:
        raise failure[0]


def read_ready(path: Path) -> dict[str, Any]:
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        if path.exists():
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                time.sleep(0.05)
                continue
            if isinstance(value, dict) and int(value.get("port", 0)) > 0 and value.get("token"):
                return value
        time.sleep(0.05)
    raise RuntimeError("timed out waiting for the live GSP qualification controller")


def receive_json(sock, deadline: float) -> dict[str, Any]:
    while time.monotonic() < deadline:
        opcode, payload = receive_frame(sock)
        if opcode == 1:
            value = json.loads(payload.decode("utf-8"))
            if isinstance(value, dict):
                return value
    raise RuntimeError("timed out waiting for GSP data")


def receive_until(sock, message_type: str, timeout_seconds: float) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    deadline = time.monotonic() + timeout_seconds
    observed: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        message = receive_json(sock, deadline)
        observed.append(message)
        if message.get("t") == message_type:
            return message, observed
    raise RuntimeError(f"timed out waiting for GSP {message_type}")


def telemetry_position_error(message: dict[str, Any]) -> float | None:
    data = message.get("d")
    if not isinstance(data, dict):
        return None
    position = data.get("pos_ned")
    if not isinstance(position, dict):
        return None
    try:
        vector = (float(position["x_val"]), float(position["y_val"]), float(position["z_val"]))
    except (KeyError, TypeError, ValueError):
        return None
    return math.dist(vector, TARGET_NED)


def telemetry_lean(message: dict[str, Any]) -> float | None:
    data = message.get("d")
    if not isinstance(data, dict):
        return None
    attitude = data.get("att_euler_deg")
    if not isinstance(attitude, list) or len(attitude) < 2:
        return None
    try:
        return max(abs(math.radians(float(attitude[0]))), abs(math.radians(float(attitude[1]))))
    except (TypeError, ValueError):
        return None


def actuator_observation(message: dict[str, Any]) -> dict[str, Any] | None:
    data = message.get("d")
    if not isinstance(data, dict):
        return None
    px4 = data.get("px4_mavlink")
    if not isinstance(px4, dict):
        return None
    actuator = px4.get("hil_actuator_controls")
    if not isinstance(actuator, dict):
        return None
    sample = actuator.get("sample")
    commands = sample.get("command_normalized") if isinstance(sample, dict) else None
    outputs = [commands.get(f"m{index}") for index in range(1, 5)] if isinstance(commands, dict) else []
    valid_outputs = len(outputs) == 4 and all(isinstance(value, (int, float)) and math.isfinite(value) for value in outputs)
    return {
        "fresh": actuator.get("source") == "px4_mavlink" and actuator.get("stale") is False and valid_outputs,
        "mapping_verified": bool(sample.get("mapping_verified", False)) if isinstance(sample, dict) else False,
        "age_seconds": actuator.get("age_seconds"),
        "outputs": outputs,
    }


def public_message(message: dict[str, Any]) -> dict[str, Any]:
    """Persist protocol evidence without the connection token."""
    value = json.loads(json.dumps(message))
    if value.get("t") == "hello" and isinstance(value.get("d"), dict):
        value["d"].pop("token", None)
    return value


def read_bridge_trace(path: Path) -> dict[str, Any]:
    """Read an opt-in Godot diagnostic trace without changing mission gates."""
    if not path.exists():
        return {"available": False, "reason": "trace_file_missing"}
    for _attempt in range(5):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            time.sleep(0.02)
            continue
        if isinstance(value, dict):
            return value
        return {"available": False, "reason": "trace_file_not_object"}
    return {"available": False, "reason": "trace_file_not_valid_json"}


def qualification_readiness_failure(trace: dict[str, Any]) -> str:
    """Return the unmet physical-readiness proof, without issuing flight commands."""
    bridge_events = trace.get("bridge_events")
    runtime_events = trace.get("runtime_authority_events")
    if not isinstance(bridge_events, list) or not isinstance(runtime_events, list):
        return "PX4 qualification trace is unavailable"
    takeoff_acks = [event for event in bridge_events if isinstance(event, dict) and event.get("kind") == "command_ack" and event.get("command") == 22]
    if not any(event.get("result") == 0 for event in takeoff_acks):
        return "PX4 CMD22 ACK=0 was not observed"
    if not any(event.get("kind") == "estimator_status" and event.get("estimator_ready") is True for event in bridge_events if isinstance(event, dict)):
        return "PX4 estimator readiness was not observed"
    if not any(event.get("state") == "armed" and event.get("authority_active") is True for event in bridge_events if isinstance(event, dict)):
        return "PX4 armed authority was not observed"
    if not any(
        event.get("kind") == "hil_actuator_controls"
        and event.get("authority_active") is True
        and isinstance(event.get("outputs"), list)
        and any(isinstance(value, (int, float)) and math.isfinite(value) and abs(value) > 0.05 for value in event["outputs"])
        for event in bridge_events
        if isinstance(event, dict)
    ):
        return "post-takeoff nonzero PX4 actuator output was not observed"
    if not any(isinstance(event.get("px4_collision_input"), dict) and event["px4_collision_input"] for event in runtime_events if isinstance(event, dict)):
        return "PX4 collision input was not observed"
    return ""


def wait_for_qualification_readiness(path: Path, timeout_seconds: float = 5.0) -> None:
    deadline = time.monotonic() + timeout_seconds
    failure = "PX4 qualification trace is unavailable"
    while time.monotonic() < deadline:
        failure = qualification_readiness_failure(read_bridge_trace(path))
        if not failure:
            return
        time.sleep(0.05)
    raise RuntimeError(failure)


def main() -> int:
    global airsim, arm_with_startup_retry, disarm_with_retry, wait_for_landed
    global receive_frame, send_text, websocket_connect
    if not qualification_corridor_is_clear():
        raise RuntimeError("PX4 wind-step qualification route intersects RuntimeWall")
    import airsim as airsim_module
    from px4_sitl_mission import arm_with_startup_retry as arm_with_startup_retry_impl
    from px4_sitl_mission import disarm_with_retry as disarm_with_retry_impl
    from px4_sitl_mission import wait_for_landed as wait_for_landed_impl
    from test_gsp_transport import receive_frame as receive_frame_impl
    from test_gsp_transport import send_text as send_text_impl
    from test_gsp_transport import websocket_connect as websocket_connect_impl

    airsim = airsim_module
    arm_with_startup_retry = arm_with_startup_retry_impl
    disarm_with_retry = disarm_with_retry_impl
    wait_for_landed = wait_for_landed_impl
    receive_frame = receive_frame_impl
    send_text = send_text_impl
    websocket_connect = websocket_connect_impl

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=41451)
    parser.add_argument("--gsp-ready-file", required=True)
    parser.add_argument("--px4-trace-file", required=True)
    parser.add_argument("--evidence-output", required=True)
    args = parser.parse_args()

    raw: dict[str, Any] = {"kind": "aerosim.px4_wind_step_raw", "px4_revision": PX4_REVISION, "transport": "real"}
    telemetry: list[dict[str, Any]] = []
    acknowledgement: dict[str, Any] = {}
    terminal_landed = False
    client = None
    failure = ""
    try:
        ready = read_ready(Path(args.gsp_ready_file))
        client = airsim.MultirotorClient(ip="127.0.0.1", port=args.port)
        with websocket_connect("127.0.0.1", int(ready["port"])) as sock:
            send_text(sock, json.dumps({"v": 2, "t": "auth", "seq": 0, "d": {"token": str(ready["token"])}}))
            hello, initial_messages = receive_until(sock, "hello", 10.0)
            raw["hello"] = public_message(hello)
            raw["initial_messages"] = [public_message(message) for message in initial_messages if message.get("t") == "telemetry"]

            client.confirmConnection()
            client.enableApiControl(True, vehicle_name="Drone1")
            arm_with_startup_retry(client)
            wait_for_async_command(lambda: client.takeoffAsync(vehicle_name="Drone1"), "takeoff")
            wait_for_qualification_readiness(Path(args.px4_trace_file))
            wait_for_async_command(lambda: client.moveToPositionAsync(*TARGET_NED, 1.0, vehicle_name="Drone1"), "move_to_position")
            wait_for_async_command(lambda: client.hoverAsync(vehicle_name="Drone1"), "hover")

            command = {"v": 2, "t": "set_wind", "seq": 1, "d": {"wind_from_deg": WIND_FROM_DEG, "speed_mps": WIND_SPEED_MPS}}
            raw["command"] = command
            send_text(sock, json.dumps(command, separators=(",", ":")))
            acknowledgement, messages_before_ack = receive_until(sock, "wind_ack", 10.0)
            raw["ack"] = public_message(acknowledgement)

            telemetry = [message for message in messages_before_ack if message.get("t") == "telemetry"]
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                try:
                    message = receive_json(sock, deadline)
                except TimeoutError:
                    break
                if message.get("t") == "telemetry":
                    telemetry.append(message)
            raw["telemetry"] = [public_message(message) for message in telemetry]

            wait_for_async_command(lambda: client.landAsync(vehicle_name="Drone1"), "land")
            landed = wait_for_landed(client)
            terminal_landed = int(landed.landed_state) == int(airsim.LandedState.Landed)
            raw["terminal"] = {"landed_state": int(landed.landed_state)}
            if not terminal_landed:
                raise RuntimeError("PX4 terminal state is not landed")
            disarm_with_retry(client)
    except (RuntimeError, TimeoutError) as error:
        failure = str(error)
        raw["failure"] = {"reason": failure}
    finally:
        if client is not None:
            try:
                client.enableApiControl(False, vehicle_name="Drone1")
            except Exception as error:
                raw.setdefault("cleanup_errors", []).append(str(error))

    position_errors = [error for message in telemetry if (error := telemetry_position_error(message)) is not None]
    leans = [lean for message in telemetry if (lean := telemetry_lean(message)) is not None]
    actuator_rows = [row for message in telemetry if (row := actuator_observation(message)) is not None]
    latest_actuator = actuator_rows[-1] if actuator_rows else {"fresh": False, "mapping_verified": False, "age_seconds": None}
    ack_data = acknowledgement.get("d") if isinstance(acknowledgement.get("d"), dict) else {}
    event_identity = ack_data.get("replay_event_identity") if isinstance(ack_data.get("replay_event_identity"), dict) else {}
    applied_tick = ack_data.get("applied_tick")
    observed_authorities = {
        message.get("d", {}).get("authority")
        for message in telemetry
        if isinstance(message.get("d"), dict)
    }
    evidence = {
        "kind": "aerosim.px4_wind_step_qualification",
        "px4_revision": PX4_REVISION,
        "transport": "real",
        "authority": "px4_exclusive" if observed_authorities == {"px4_external"} else "unverified",
        "wind": {
            "applied_tick": applied_tick,
            "replay_event_tick": event_identity.get("physics_tick"),
            "replay_identity": json.dumps(event_identity, sort_keys=True) if event_identity else "",
        },
        "actuators": latest_actuator,
        "lean": {"observed": bool(leans and max(leans) > 0.0), "max_abs_roll_or_pitch_rad": max(leans) if leans else 0.0},
        "position_error_m": position_errors,
        "limits": {"rms_m": POSITION_RMS_LIMIT_M, "max_m": POSITION_MAX_LIMIT_M},
        "raw_evidence": raw,
        "bridge_trace": read_bridge_trace(Path(args.px4_trace_file)),
    }
    Path(args.evidence_output).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"completed": terminal_landed and not failure, "evidence": args.evidence_output, "failure": failure}, sort_keys=True))
    return 0 if terminal_landed and not failure else 1


if __name__ == "__main__":
    raise SystemExit(main())
