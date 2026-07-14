import argparse
import json

import airsim


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=41451)
    args = parser.parse_args()

    client = airsim.MultirotorClient(ip="127.0.0.1", port=args.port)
    client.confirmConnection()
    client.enableApiControl(True, vehicle_name="Drone1")
    if not client.armDisarm(True, vehicle_name="Drone1"):
        raise RuntimeError("PX4 armDisarm(true) failed")
    if not client.takeoffAsync(vehicle_name="Drone1").join():
        raise RuntimeError("PX4 takeoff failed")
    if not client.moveToPositionAsync(2.0, -1.0, -3.0, 1.0, vehicle_name="Drone1").join():
        raise RuntimeError("PX4 waypoint failed")
    if not client.hoverAsync(vehicle_name="Drone1").join():
        raise RuntimeError("PX4 hover failed")
    if not client.landAsync(vehicle_name="Drone1").join():
        raise RuntimeError("PX4 land failed")
    if not client.armDisarm(False, vehicle_name="Drone1"):
        raise RuntimeError("PX4 armDisarm(false) failed")
    state = client.getMultirotorState(vehicle_name="Drone1")
    client.enableApiControl(False, vehicle_name="Drone1")
    print(json.dumps({
        "completed": True,
        "landed_state": int(state.landed_state),
        "timestamp": int(state.timestamp),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
