#!/usr/bin/env python3
"""Exercise the frozen RPC subset through the unmodified AirSim 1.8.1 client."""

import argparse
import json

import airsim


def expect_rpc_error(client: airsim.VehicleClient) -> None:
    try:
        client.client.call("futureApi")
    except Exception as exc:  # msgpack-rpc-python exposes RPCError by version.
        if "unsupported RPC method" not in str(exc):
            raise AssertionError(f"unexpected unsupported-method error: {exc}") from exc
        return
    raise AssertionError("unsupported RPC method unexpectedly succeeded")


def join_true(future) -> None:
    future.join()
    assert future.get() is True


def exercise(port: int) -> None:
    client = airsim.MultirotorClient(ip="127.0.0.1", port=port, timeout_value=30)
    assert client.ping() is True
    assert client.getServerVersion() == 1
    assert client.getMinRequiredClientVersion() == 1
    settings = json.loads(client.getSettingsString())
    assert settings["SettingsVersion"] == 1.2
    assert settings["ApiServerPort"] == port
    assert settings["ClockType"] == "SteppableClock"
    assert settings["Vehicles"]["Drone1"]["VehicleType"] == "SimpleFlight"

    client.simPause(True)
    assert client.simIsPause() is True
    client.simContinueForFrames(4)
    assert client.simIsPause() is True
    client.simContinueForTime(2.0 / 240.0)
    assert client.simIsPause() is True
    client.enableApiControl(True, vehicle_name="Drone1")
    assert client.isApiControlEnabled("Drone1") is True
    assert client.armDisarm(True, vehicle_name="Drone1") is True
    assert client.listVehicles() == ["Drone1"]
    assert client.getHomeGeoPoint("Drone1").latitude == 0.0

    client.simPause(False)
    join_true(client.takeoffAsync(vehicle_name="Drone1"))
    join_true(client.moveToPositionAsync(1.0, -2.0, -3.0, 2.0, vehicle_name="Drone1"))
    join_true(client.moveOnPathAsync([airsim.Vector3r(1.0, -2.0, -3.0), airsim.Vector3r(2.0, -1.0, -4.0)], 2.0, vehicle_name="Drone1"))
    join_true(client.moveByVelocityAsync(1.0, 2.0, -1.0, 1.0, vehicle_name="Drone1"))
    join_true(client.moveByVelocityZAsync(1.0, 2.0, -4.0, 1.0, vehicle_name="Drone1"))
    join_true(client.moveByVelocityBodyFrameAsync(1.0, 0.0, 0.0, 1.0, vehicle_name="Drone1"))
    join_true(client.moveByVelocityZBodyFrameAsync(1.0, 0.0, -1.0, 1.0, vehicle_name="Drone1"))
    join_true(client.rotateToYawAsync(45.0, vehicle_name="Drone1"))
    join_true(client.rotateByYawRateAsync(10.0, 1.0, vehicle_name="Drone1"))
    join_true(client.moveByAngleRatesThrottleAsync(0.0, 0.0, 0.0, 0.5, 1.0, vehicle_name="Drone1"))
    assert abs(client.simGetVehiclePose("Drone1").position.x_val) < 1e6
    assert isinstance(client.simGetCollisionInfo("Drone1").has_collided, bool)
    join_true(client.hoverAsync(vehicle_name="Drone1"))
    join_true(client.goHomeAsync(vehicle_name="Drone1"))
    join_true(client.landAsync(vehicle_name="Drone1"))

    client.simPause(True)
    pending = client.takeoffAsync(vehicle_name="Drone1")
    client.cancelLastTask(vehicle_name="Drone1")
    pending.join()
    assert pending.get() is False
    expect_rpc_error(client)

    client.reset()
    assert client.simIsPause() is False
    close = getattr(client.client, "close", None)
    if close is not None:
        close()

    reconnected = airsim.MultirotorClient(ip="127.0.0.1", port=port, timeout_value=5)
    assert reconnected.ping() is True
    reconnected.client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    exercise(parser.parse_args().port)
