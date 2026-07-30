extends GutTest

const AirSimSensorSuite = preload("res://common/rpc/airsim_sensor_suite.gd")


func _settings(sensors: Dictionary = {}) -> Dictionary:
    return {
        "OriginGeopoint": {"Latitude": 25.0, "Longitude": 121.0, "Altitude": 100.0},
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight", "Sensors": sensors}},
    }


func _state(position := Vector3.ZERO) -> Dictionary:
    return {
        "kinematics_estimated": {
            "position": {"x_val": position.x, "y_val": position.y, "z_val": position.z},
            "orientation": {"w_val": 1.0, "x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
            "linear_velocity": {"x_val": 1.0, "y_val": 0.0, "z_val": 0.0},
            "angular_velocity": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
            "linear_acceleration": {"x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
        },
        "imu_sample": {
            "gyro": {"x_val": 0.1, "y_val": 0.2, "z_val": 0.3},
            "accel": {"x_val": 0.0, "y_val": 0.0, "z_val": -9.80665},
            "orientation": {"w_val": 1.0, "x_val": 0.0, "y_val": 0.0, "z_val": 0.0},
            "barometer_altitude_m": 0.0,
        },
    }


func test_default_suite_exposes_all_baseline_sensor_types() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)

    var result: Dictionary = suite.configure(_settings(), ["Drone1"])

    assert_true(result.ok)
    for sensor_type in [AirSimSensorSuite.SENSOR_IMU, AirSimSensorSuite.SENSOR_GPS, AirSimSensorSuite.SENSOR_MAGNETOMETER, AirSimSensorSuite.SENSOR_BAROMETER, AirSimSensorSuite.SENSOR_LIDAR]:
        assert_true(suite.has_sensor("Drone1", sensor_type, ""))


func test_sampling_uses_simulation_time_and_configured_frequency() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    assert_true(suite.configure(_settings({"imu": {"SensorType": 2, "UpdateFrequency": 10.0}}), ["Drone1"]).ok)

    suite.advance(0.0, _state())
    suite.advance(0.099, _state())
    assert_eq(suite.stats("Drone1", AirSimSensorSuite.SENSOR_IMU, "").sample_count, 1)
    suite.advance(0.1, _state())
    assert_eq(suite.stats("Drone1", AirSimSensorSuite.SENSOR_IMU, "").sample_count, 2)
    assert_eq(suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_IMU, "").time_stamp, 100000000)


func test_two_vehicle_sensor_streams_sample_their_own_state() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    var settings := _settings()
    settings["Vehicles"]["Drone2"] = {"VehicleType": "SimpleFlight", "Sensors": {}}
    assert_true(suite.configure(settings, ["Drone1", "Drone2"]).ok)

    suite.advance(1.2, "Drone1", _state(Vector3(0.0, 1.0, 0.0)))
    suite.advance(1.2, "Drone2", _state(Vector3(0.0, 9.0, 0.0)))

    var drone_a_longitude: float = float(suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_GPS, "").gnss.geo_point.longitude)
    var drone_b_longitude: float = float(suite.get_sensor("Drone2", AirSimSensorSuite.SENSOR_GPS, "").gnss.geo_point.longitude)
    assert_ne(drone_a_longitude, drone_b_longitude)
    assert_gt(drone_b_longitude, drone_a_longitude)


func test_paused_reads_do_not_change_timestamp_or_sample_count() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    assert_true(suite.configure(_settings(), ["Drone1"]).ok)
    suite.advance(0.0, _state())
    var before: Dictionary = suite.stats("Drone1", AirSimSensorSuite.SENSOR_GPS, "")
    var sample_before: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_GPS, "")

    suite.advance(0.0, _state(Vector3(3.0, 0.0, -4.0)))

    var after: Dictionary = suite.stats("Drone1", AirSimSensorSuite.SENSOR_GPS, "")
    var sample_after: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_GPS, "")
    assert_eq(after.sample_count, before.sample_count)
    assert_eq(sample_after.time_stamp, sample_before.time_stamp)


func test_gps_and_barometer_preserve_origin_and_native_altitude_semantics() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    assert_true(suite.configure(_settings(), ["Drone1"]).ok)
    var state := _state(Vector3(0.0, 0.0, -10.0))
    state.imu_sample.barometer_altitude_m = 10.0
    suite.advance(1.2, state)

    var gps: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_GPS, "")
    assert_eq(gps.time_stamp, 1000000000)
    assert_eq(gps.gnss.time_utc, 1000000)
    assert_almost_eq(gps.gnss.geo_point.altitude, 110.0, 0.0001)
    var barometer: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_BAROMETER, "")
    assert_almost_eq(barometer.altitude, 110.0, 0.0001)

    var named_gps := AirSimSensorSuite.new()
    autofree(named_gps)
    assert_true(named_gps.configure(_settings({"custom_gps": {"SensorType": AirSimSensorSuite.SENSOR_GPS}}), ["Drone1"]).ok)
    named_gps.advance(1.2, state)
    assert_eq(named_gps.get_sensor("Drone1", AirSimSensorSuite.SENSOR_GPS, "custom_gps").time_stamp, 1000000000)


func test_stationary_magnetometer_and_barometer_resample_at_50_hz_with_deterministic_noise() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    assert_true(suite.configure(_settings(), ["Drone1"]).ok)
    suite.advance(0.0, _state())
    var magnetometer_before: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_MAGNETOMETER, "")
    var barometer_before: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_BAROMETER, "")

    suite.advance(0.019, _state())
    assert_eq(suite.stats("Drone1", AirSimSensorSuite.SENSOR_MAGNETOMETER, "").sample_count, 1)
    suite.advance(0.02, _state())
    var magnetometer_after: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_MAGNETOMETER, "")
    var barometer_after: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_BAROMETER, "")

    assert_eq(magnetometer_after.time_stamp, 20_000_000)
    assert_eq(barometer_after.time_stamp, 20_000_000)
    assert_ne(magnetometer_after.magnetic_field_body.x_val, magnetometer_before.magnetic_field_body.x_val)
    assert_ne(barometer_after.pressure, barometer_before.pressure)
    assert_ne(barometer_after.temperature, barometer_before.temperature)


func test_sensor_drop_metadata_is_observable_after_a_large_simulation_gap() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    assert_true(suite.configure(_settings(), ["Drone1"]).ok)
    suite.advance(1000.0, _state())

    var result: Dictionary = suite.sensor_result("Drone1", AirSimSensorSuite.SENSOR_IMU, "")
    assert_true(result.ok)
    assert_gt(result.sensor.dropped_count, 0)
    assert_eq(result.sensor.dropped_count, suite.stats("Drone1", AirSimSensorSuite.SENSOR_IMU, "").dropped_count)
    assert_eq(result.sensor.aerosim_identity.vehicle_name, "Drone1")


func test_sensor_names_and_invalid_requests_fail_loudly() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    var result: Dictionary = suite.configure(_settings({"imu": {"SensorType": 2, "UpdateFrequency": 0.0}}), ["Drone1"])

    assert_false(result.ok)
    assert_string_contains(result.error, "UpdateFrequency")
    assert_false(suite.has_sensor("Drone1", AirSimSensorSuite.SENSOR_IMU, "missing"))

    var disabled := AirSimSensorSuite.new()
    autofree(disabled)
    assert_true(disabled.configure(_settings({"imu": {"SensorType": 2, "Enabled": false}}), ["Drone1"]).ok)
    assert_false(disabled.has_sensor("Drone1", AirSimSensorSuite.SENSOR_IMU, ""))


func test_lidar_payload_is_little_endian_float32_and_local_ned() -> void:
    var suite := AirSimSensorSuite.new()
    autofree(suite)
    assert_true(suite.configure(_settings(), ["Drone1"]).ok)
    suite.advance(0.0, _state(Vector3(0.0, 0.0, -5.0)))

    var lidar: Dictionary = suite.get_sensor("Drone1", AirSimSensorSuite.SENSOR_LIDAR, "")
    assert_true(lidar.point_cloud is PackedFloat32Array)
    assert_eq(lidar.point_cloud.size(), 12)
    assert_eq(lidar.point_cloud[2], 5.0)
    assert_eq(lidar.segmentation.size(), 4)
