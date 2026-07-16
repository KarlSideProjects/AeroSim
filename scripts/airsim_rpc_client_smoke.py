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


def exercise(port: int, dual: bool = False) -> None:
    client = airsim.MultirotorClient(ip="127.0.0.1", port=port, timeout_value=30)
    vehicle_names = ["Drone1", "Drone2"] if dual else ["Drone1"]
    assert client.ping() is True
    assert client.getServerVersion() == 1
    assert client.getMinRequiredClientVersion() == 1
    settings = json.loads(client.getSettingsString())
    assert settings["SettingsVersion"] == 1.2
    assert settings["ApiServerPort"] == port
    assert settings["ClockType"] == "SteppableClock"
    assert settings["Vehicles"]["Drone1"]["VehicleType"] == "SimpleFlight"
    if dual:
        assert settings["Vehicles"]["Drone2"]["VehicleType"] == "SimpleFlight"

    client.simPause(True)
    assert client.simIsPause() is True
    client.simContinueForFrames(4)
    assert client.simIsPause() is True
    client.simContinueForTime(2.0 / 240.0)
    assert client.simIsPause() is True
    samples = {}
    for vehicle_name in vehicle_names:
        samples[vehicle_name] = {
            "imu": client.getImuData(vehicle_name=vehicle_name),
            "gps": client.getGpsData(vehicle_name=vehicle_name),
            "magnetometer": client.getMagnetometerData(vehicle_name=vehicle_name),
            "barometer": client.getBarometerData(vehicle_name=vehicle_name),
            "lidar": client.getLidarData(vehicle_name=vehicle_name),
            "state": client.getMultirotorState(vehicle_name=vehicle_name),
        }
    imu = samples["Drone1"]["imu"]
    gps = samples["Drone1"]["gps"]
    magnetometer = samples["Drone1"]["magnetometer"]
    barometer = samples["Drone1"]["barometer"]
    lidar = samples["Drone1"]["lidar"]
    raw_imu = client.client.call("getImuData", "", "Drone1")
    state = samples["Drone1"]["state"]
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
    assert state.kinematics_estimated is not None
    assert state.ready is True
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
    if dual:
        secondary_images = client.simGetImages([
            airsim.ImageRequest("0", airsim.ImageType.Segmentation, False, False),
            airsim.ImageRequest("0", airsim.ImageType.DepthPlanar, True, False),
        ], vehicle_name="Drone2")
        assert [response.image_type for response in secondary_images] == [airsim.ImageType.Segmentation, airsim.ImageType.DepthPlanar]
        assert secondary_images[0].width == secondary_images[1].width == 256
        assert secondary_images[0].height == secondary_images[1].height == 144
        assert len(secondary_images[0].image_data_uint8) == 256 * 144 * 3
        assert len(secondary_images[1].image_data_float) == 256 * 144
    client.enableApiControl(True, vehicle_name="Drone1")
    assert client.isApiControlEnabled("Drone1") is True
    assert client.armDisarm(True, vehicle_name="Drone1") is True
    assert client.listVehicles() == vehicle_names
    assert client.getHomeGeoPoint("Drone1").latitude == 0.0

    if dual:
        client.enableApiControl(True, vehicle_name="Drone2")
        assert client.isApiControlEnabled("Drone2") is True
        assert client.armDisarm(True, vehicle_name="Drone2") is True
        secondary_state = samples["Drone2"]["state"]
        assert secondary_state.kinematics_estimated is not None
        assert secondary_state.ready is True

    client.simPause(False)
    if dual:
        first_takeoff = client.takeoffAsync(vehicle_name="Drone1")
        second_takeoff = client.takeoffAsync(vehicle_name="Drone2")
        first_takeoff.join()
        second_takeoff.join()
        assert first_takeoff.get() is True
        assert second_takeoff.get() is True
        first_move = client.moveToPositionAsync(1.0, -2.0, -3.0, 2.0, vehicle_name="Drone1")
        second_move = client.moveToPositionAsync(-2.0, 1.0, -2.0, 2.0, vehicle_name="Drone2")
        first_move.join()
        second_move.join()
        assert first_move.get() is True
        assert second_move.get() is True
        client.simPause(True)
        primary_pose = client.simGetVehiclePose("Drone1")
        secondary_pose = client.simGetVehiclePose("Drone2")
        assert primary_pose.position.distance_to(secondary_pose.position) > 1.0
        moved_samples = {
            vehicle_name: {
                "imu": client.getImuData(vehicle_name=vehicle_name),
                "gps": client.getGpsData(vehicle_name=vehicle_name),
                "state": client.getMultirotorState(vehicle_name=vehicle_name),
            }
            for vehicle_name in vehicle_names
        }
        for vehicle_name, pose in [("Drone1", primary_pose), ("Drone2", secondary_pose)]:
            state = moved_samples[vehicle_name]["state"]
            position = state.kinematics_estimated.position
            assert position.distance_to(pose.position) < 0.01, f"{vehicle_name} state {position} != pose {pose.position}"
            assert state.ready is True
            assert moved_samples[vehicle_name]["imu"].time_stamp >= samples[vehicle_name]["imu"].time_stamp
        primary_gps = moved_samples["Drone1"]["gps"].gnss.geo_point
        secondary_gps = moved_samples["Drone2"]["gps"].gnss.geo_point
        assert abs(primary_gps.latitude - secondary_gps.latitude) > 1e-6
        assert abs(primary_gps.longitude - secondary_gps.longitude) > 1e-6
        primary_images = client.simGetImages([
            airsim.ImageRequest("0", airsim.ImageType.Segmentation, False, False),
        ], vehicle_name="Drone1")
        secondary_images = client.simGetImages([
            airsim.ImageRequest("0", airsim.ImageType.Segmentation, False, False),
        ], vehicle_name="Drone2")
        assert primary_images[0].camera_position.distance_to(secondary_images[0].camera_position) > 1.0
        camera_delta = primary_images[0].camera_position - secondary_images[0].camera_position
        pose_delta = primary_pose.position - secondary_pose.position
        assert camera_delta.distance_to(pose_delta) < 0.01
        assert primary_images[0].image_data_uint8 != secondary_images[0].image_data_uint8
        client.enableApiControl(False, vehicle_name="Drone1")
        assert client.isApiControlEnabled("Drone1") is False
        assert client.isApiControlEnabled("Drone2") is True
        client.enableApiControl(True, vehicle_name="Drone1")
        assert client.armDisarm(True, vehicle_name="Drone1") is True
        client.reset()
        assert client.simIsPause() is False
        client.client.close()
        return
    else:
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
    parser.add_argument("--dual", action="store_true")
    args = parser.parse_args()
    exercise(args.port, dual=args.dual)
