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
TARGET_NED = (2.0, -1.0, -3.0)
POSITION_RMS_LIMIT_M = 0.75
POSITION_MAX_LIMIT_M = 1.25
ASYNC_COMMAND_TIMEOUT_SECONDS = 45.0


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


def main() -> int:
    global airsim, arm_with_startup_retry, disarm_with_retry, wait_for_landed
    global receive_frame, send_text, websocket_connect
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
