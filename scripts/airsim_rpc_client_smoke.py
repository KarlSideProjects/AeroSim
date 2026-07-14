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
    imu = client.getImuData(vehicle_name="Drone1")
    gps = client.getGpsData(vehicle_name="Drone1")
    magnetometer = client.getMagnetometerData(vehicle_name="Drone1")
    barometer = client.getBarometerData(vehicle_name="Drone1")
    lidar = client.getLidarData(vehicle_name="Drone1")
    raw_imu = client.client.call("getImuData", "", "Drone1")
    for sensor in [imu, gps, magnetometer, barometer, lidar]:
        assert sensor.time_stamp >= 0
    assert imu.orientation is not None
    assert len(imu.angular_velocity.to_msgpack()) == 3
    assert gps.is_valid is True
    assert gps.gnss.geo_point is not None
    assert len(magnetometer.magnetic_field_covariance) == 9
    assert barometer.qnh > 0.0
    assert len(lidar.point_cloud) % 3 == 0
    assert len(lidar.segmentation) == len(lidar.point_cloud) // 3
    assert raw_imu["sample_count"] >= 1
    assert raw_imu["dropped_count"] == 0
    images = client.simGetImages([
        airsim.ImageRequest("0", airsim.ImageType.Segmentation, False, False),
        airsim.ImageRequest("0", airsim.ImageType.DepthPlanar, True, False),
    ], vehicle_name="Drone1")
    assert [response.image_type for response in images] == [airsim.ImageType.Segmentation, airsim.ImageType.DepthPlanar]
    assert images[0].width == images[1].width == 256
    assert images[0].height == images[1].height == 144
    assert isinstance(images[0].image_data_uint8, (bytes, bytearray))
    assert len(images[0].image_data_uint8) == 256 * 144 * 3
    assert len(images[1].image_data_float) == 256 * 144
    assert images[0].time_stamp == images[1].time_stamp
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
