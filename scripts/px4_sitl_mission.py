import argparse
import json
import time

import airsim


def progress(message: str) -> None:
    print(message, flush=True)


def arm_with_startup_retry(client: airsim.MultirotorClient, attempts: int = 100) -> None:
    last_error = None
    for _ in range(attempts):
        try:
            if client.armDisarm(True, vehicle_name="Drone1"):
                return
            last_error = RuntimeError("PX4 armDisarm(true) failed")
        except Exception as error:  # AirSim wraps the bridge startup state as RPCError.
            last_error = error
        time.sleep(0.1)
    raise RuntimeError(f"PX4 did not become armable during startup: {last_error}")


def disarm_with_retry(client: airsim.MultirotorClient, attempts: int = 100) -> None:
    last_error = None
    for _ in range(attempts):
        try:
            if client.armDisarm(False, vehicle_name="Drone1"):
                return
            last_error = RuntimeError("PX4 armDisarm(false) is still pending")
        except Exception as error:
            last_error = error
        time.sleep(0.1)
    raise RuntimeError(f"PX4 did not confirm disarm: {last_error}")


def wait_for_landed(client: airsim.MultirotorClient, timeout_seconds: float = 15.0):
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        state = client.getMultirotorState(vehicle_name="Drone1")
        if int(state.landed_state) == int(airsim.LandedState.Landed):
            return state
        time.sleep(0.1)
    return client.getMultirotorState(vehicle_name="Drone1")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=41451)
    args = parser.parse_args()

    client = airsim.MultirotorClient(ip="127.0.0.1", port=args.port)
    progress("confirming AirSim connection")
    client.confirmConnection()
    progress("enabling API control")
    client.enableApiControl(True, vehicle_name="Drone1")
    progress("arming PX4")
    arm_with_startup_retry(client)
    progress("taking off")
    client.takeoffAsync(vehicle_name="Drone1").join()
    progress("moving to position")
    client.moveToPositionAsync(2.0, -1.0, -3.0, 1.0, vehicle_name="Drone1").join()
    progress("hovering")
    client.hoverAsync(vehicle_name="Drone1").join()
    progress("landing")
    client.landAsync(vehicle_name="Drone1").join()
    state = wait_for_landed(client)
    if int(state.landed_state) != int(airsim.LandedState.Landed):
        position = state.kinematics_estimated.position
        velocity = state.kinematics_estimated.linear_velocity
        raise RuntimeError(
            "PX4 terminal state is not landed: "
            f"landed_state={int(state.landed_state)} "
            f"position=({position.x_val:.3f},{position.y_val:.3f},{position.z_val:.3f}) "
            f"velocity=({velocity.x_val:.3f},{velocity.y_val:.3f},{velocity.z_val:.3f})"
        )
    disarm_with_retry(client)
    terminal_state = client.getMultirotorState(vehicle_name="Drone1")
    if int(terminal_state.landed_state) != int(airsim.LandedState.Landed):
        raise RuntimeError("PX4 terminal state was not landed after disarm confirmation")
    client.enableApiControl(False, vehicle_name="Drone1")
    progress("mission complete")
    print(json.dumps({
        "completed": True,
        "landed_state": int(state.landed_state),
        "timestamp": int(state.timestamp),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
