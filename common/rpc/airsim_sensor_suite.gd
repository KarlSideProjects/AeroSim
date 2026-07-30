class_name AirSimSensorSuite
extends RefCounted

const SENSOR_BAROMETER := 1
const SENSOR_IMU := 2
const SENSOR_GPS := 3
const SENSOR_MAGNETOMETER := 4
const SENSOR_LIDAR := 6
const SENSOR_TYPES := [SENSOR_BAROMETER, SENSOR_IMU, SENSOR_GPS, SENSOR_MAGNETOMETER, SENSOR_LIDAR]
const DEFAULT_SENSOR_NAMES := {
    SENSOR_IMU: "imu",
    SENSOR_GPS: "gps",
    SENSOR_MAGNETOMETER: "magnetometer",
    SENSOR_BAROMETER: "barometer",
    SENSOR_LIDAR: "lidar",
}
const DEFAULT_SENSOR_RATES := {
    SENSOR_IMU: 240.0,
    SENSOR_GPS: 50.0,
    SENSOR_MAGNETOMETER: 50.0,
    SENSOR_BAROMETER: 50.0,
    SENSOR_LIDAR: 10.0,
}
const DEFAULT_SENSOR_LATENCIES := {
    SENSOR_IMU: 0.0,
    SENSOR_GPS: 0.2,
    SENSOR_MAGNETOMETER: 0.0,
    SENSOR_BAROMETER: 0.0,
    SENSOR_LIDAR: 0.0,
}
const DEFAULT_SENSOR_STARTUPS := {
    SENSOR_IMU: 0.0,
    SENSOR_GPS: 1.0,
    SENSOR_MAGNETOMETER: 0.0,
    SENSOR_BAROMETER: 0.0,
    SENSOR_LIDAR: 0.0,
}
const EARTH_RADIUS_M := 6378137.0
const MAGNETIC_FIELD_NED_GAUSS := Vector3(0.22, 0.0, 0.43)
const MAX_CATCHUP_SAMPLES := 4096
const DETERMINISTIC_NOISE_SEED := 0.61803398875
const MAGNETOMETER_NOISE_GAUSS := 0.0005
const BAROMETER_PRESSURE_NOISE_PA := 0.15
const BAROMETER_TEMPERATURE_C := 25.0
const BAROMETER_TEMPERATURE_NOISE_C := 0.02

var _streams: Dictionary = {}
var _stream_order: Array[Dictionary] = []
var _origin: Dictionary = {}
var _last_time_seconds := 0.0
var _last_time_seconds_by_vehicle: Dictionary = {}


func configure(settings: Dictionary, vehicle_names: Array) -> Dictionary:
    _streams.clear()
    _stream_order.clear()
    _last_time_seconds = 0.0
    _last_time_seconds_by_vehicle.clear()
    _origin = settings.get("OriginGeopoint", {}).duplicate(true)
    var errors: Array[String] = []
    var configured_vehicles: Dictionary = settings.get("Vehicles", {})
    for vehicle_name_variant in vehicle_names:
        var vehicle_name := String(vehicle_name_variant)
        var vehicle: Dictionary = configured_vehicles.get(vehicle_name, {})
        var configured_sensors: Dictionary = vehicle.get("Sensors", {})
        var configured_types: Dictionary = {}
        for sensor_name_variant in configured_sensors:
            var sensor_name := String(sensor_name_variant)
            if typeof(sensor_name_variant) != TYPE_STRING or sensor_name.is_empty():
                errors.append("Vehicles.%s.Sensors names must be non-empty strings" % vehicle_name)
                continue
            var raw = configured_sensors[sensor_name_variant]
            if typeof(raw) != TYPE_DICTIONARY:
                errors.append("Vehicles.%s.Sensors.%s must be an object" % [vehicle_name, sensor_name])
                continue
            var sensor: Dictionary = raw
            var raw_sensor_type = sensor.get("SensorType", -1)
            if typeof(raw_sensor_type) not in [TYPE_INT, TYPE_FLOAT] or not is_equal_approx(float(raw_sensor_type), roundf(float(raw_sensor_type))):
                errors.append("Vehicles.%s.Sensors.%s.SensorType must be an integer" % [vehicle_name, sensor_name])
                continue
            var sensor_type := int(raw_sensor_type)
            if not SENSOR_TYPES.has(sensor_type):
                errors.append("Vehicles.%s.Sensors.%s.SensorType is unsupported" % [vehicle_name, sensor_name])
                continue
            configured_types[sensor_type] = true
            if sensor.has("Enabled") and typeof(sensor["Enabled"]) == TYPE_BOOL and not sensor["Enabled"]:
                continue
            var rate := float(sensor.get("UpdateFrequency", DEFAULT_SENSOR_RATES[sensor_type]))
            if not is_finite(rate) or rate <= 0.0:
                errors.append("Vehicles.%s.Sensors.%s.UpdateFrequency must be positive" % [vehicle_name, sensor_name])
                continue
            var latency := float(sensor.get("UpdateLatency", DEFAULT_SENSOR_LATENCIES[sensor_type]))
            var startup_delay := float(sensor.get("StartupDelay", DEFAULT_SENSOR_STARTUPS[sensor_type]))
            if not is_finite(latency) or latency < 0.0:
                errors.append("Vehicles.%s.Sensors.%s.UpdateLatency must not be negative" % [vehicle_name, sensor_name])
                continue
            if not is_finite(startup_delay) or startup_delay < 0.0:
                errors.append("Vehicles.%s.Sensors.%s.StartupDelay must not be negative" % [vehicle_name, sensor_name])
                continue
            var stream := _make_stream(vehicle_name, sensor_name, sensor_type, rate, latency, startup_delay, sensor)
            _add_stream(stream)
        for sensor_type in SENSOR_TYPES:
            if configured_types.has(sensor_type):
                continue
            _add_stream(_make_stream(
                vehicle_name,
                DEFAULT_SENSOR_NAMES[sensor_type],
                sensor_type,
                DEFAULT_SENSOR_RATES[sensor_type],
                DEFAULT_SENSOR_LATENCIES[sensor_type],
                DEFAULT_SENSOR_STARTUPS[sensor_type]
            ))
    return {"ok": errors.is_empty(), "error": "; ".join(errors), "errors": errors}


func advance(simulation_time_seconds: float, vehicle_or_state: Variant, state: Dictionary = {}) -> void:
    if typeof(vehicle_or_state) == TYPE_DICTIONARY and state.is_empty():
        if not is_finite(simulation_time_seconds) or simulation_time_seconds < _last_time_seconds:
            return
        _last_time_seconds = simulation_time_seconds
        for vehicle_name in _vehicle_names():
            _advance_vehicle(simulation_time_seconds, String(vehicle_name), vehicle_or_state)
        return
    if typeof(vehicle_or_state) != TYPE_STRING or typeof(state) != TYPE_DICTIONARY:
        return
    var vehicle_name := String(vehicle_or_state)
    var last_time := float(_last_time_seconds_by_vehicle.get(vehicle_name, 0.0))
    if not is_finite(simulation_time_seconds) or simulation_time_seconds < last_time:
        return
    _last_time_seconds_by_vehicle[vehicle_name] = simulation_time_seconds
    _advance_vehicle(simulation_time_seconds, vehicle_name, state)


func _advance_vehicle(simulation_time_seconds: float, vehicle_name: String, state: Dictionary) -> void:
    for stream in _stream_order:
        if String(stream.vehicle_name) != vehicle_name:
            continue
        var next_time := float(stream.next_sample_time)
        var produced := 0
        while next_time <= simulation_time_seconds + 1e-9 and produced < MAX_CATCHUP_SAMPLES:
            var sample := _sample(stream, state, next_time)
            stream.history.append(sample)
            stream.sample_count = int(stream.sample_count) + 1
            next_time += float(stream.period_seconds)
            produced += 1
        if next_time <= simulation_time_seconds + 1e-9:
            var skipped := ceili((simulation_time_seconds - next_time) / float(stream.period_seconds)) + 1
            stream.dropped_count = int(stream.dropped_count) + skipped
            next_time += float(skipped) * float(stream.period_seconds)
        stream.next_sample_time = next_time
        var ready_time := simulation_time_seconds - float(stream.latency_seconds)
        for sample in stream.history:
            if float(sample["time_stamp"]) / 1_000_000_000.0 <= ready_time + 1e-9:
                stream.latest = sample
        while stream.history.size() > 2 and float(stream.history[1]["time_stamp"]) / 1_000_000_000.0 <= ready_time:
            stream.history.pop_front()


func _vehicle_names() -> Array:
    var names := []
    for stream in _stream_order:
        var name := String(stream.vehicle_name)
        if not names.has(name):
            names.append(name)
    return names


func sensor_result(vehicle_name: String, sensor_type: int, sensor_name: String) -> Dictionary:
    var stream := _find_stream(vehicle_name, sensor_type, sensor_name)
    if stream.is_empty():
        return {"ok": false, "error": "sensor is not configured: %s/%s" % [sensor_name, sensor_type]}
    var sensor: Dictionary = stream.latest.duplicate(true)
    sensor["sample_count"] = int(stream.sample_count)
    sensor["dropped_count"] = int(stream.dropped_count)
    return {"ok": true, "sensor": sensor}


func get_sensor(vehicle_name: String, sensor_type: int, sensor_name: String) -> Dictionary:
    var result := sensor_result(vehicle_name, sensor_type, sensor_name)
    return result.sensor if result.ok else {}


func has_sensor(vehicle_name: String, sensor_type: int, sensor_name: String) -> bool:
    return not _find_stream(vehicle_name, sensor_type, sensor_name).is_empty()


func stats(vehicle_name: String, sensor_type: int, sensor_name: String) -> Dictionary:
    var stream := _find_stream(vehicle_name, sensor_type, sensor_name)
    if stream.is_empty():
        return {}
    return {
        "sample_count": int(stream.sample_count),
        "dropped_count": int(stream.dropped_count),
        "last_sample_time": float(stream.latest.get("time_stamp", 0)) / 1_000_000_000.0,
        "frequency_hz": float(stream.frequency_hz),
    }


func _make_stream(vehicle_name: String, sensor_name: String, sensor_type: int, frequency_hz: float, latency_seconds: float, startup_delay: float, sensor: Dictionary = {}) -> Dictionary:
    var empty_state := {
        "kinematics_estimated": {"position": _vec3(0.0, 0.0, 0.0), "orientation": _quat(1.0, 0.0, 0.0, 0.0), "linear_velocity": _vec3(0.0, 0.0, 0.0)},
        "imu_sample": {},
    }
    var stream := {
        "vehicle_name": vehicle_name,
        "sensor_name": sensor_name,
        "sensor_type": sensor_type,
        "frequency_hz": frequency_hz,
        "period_seconds": 1.0 / frequency_hz,
        "latency_seconds": latency_seconds,
        "next_sample_time": startup_delay,
        "sample_count": 0,
        "dropped_count": 0,
        "mount_position": _vec3(float(sensor.get("X", 0.0)), float(sensor.get("Y", 0.0)), float(sensor.get("Z", 0.0))),
        "mount_orientation": _mount_orientation(sensor),
        "history": [],
        "latest": {},
    }
    stream["latest"] = _sample(stream, empty_state, 0.0)
    return stream


func _add_stream(stream: Dictionary) -> void:
    var key := _stream_key(String(stream.vehicle_name), int(stream.sensor_type), String(stream.sensor_name))
    _streams[key] = stream
    _stream_order.append(stream)


func _find_stream(vehicle_name: String, sensor_type: int, sensor_name: String) -> Dictionary:
    for stream in _stream_order:
        if String(stream.vehicle_name) != vehicle_name or int(stream.sensor_type) != sensor_type:
            continue
        if sensor_name.is_empty() or String(stream.sensor_name) == sensor_name:
            return stream
    return {}


func _stream_key(vehicle_name: String, sensor_type: int, sensor_name: String) -> String:
    return "%s/%d/%s" % [vehicle_name, sensor_type, sensor_name]


func _sample(stream: Dictionary, state: Dictionary, sample_time: float) -> Dictionary:
    var sample: Dictionary
    match int(stream.sensor_type):
        SENSOR_IMU:
            sample = _sample_imu(state, sample_time)
        SENSOR_GPS:
            sample = _sample_gps(state, sample_time)
        SENSOR_MAGNETOMETER:
            sample = _sample_magnetometer(state, sample_time)
        SENSOR_BAROMETER:
            sample = _sample_barometer(state, sample_time)
        SENSOR_LIDAR:
            sample = _sample_lidar(stream, state, sample_time)
        _:
            sample = {"time_stamp": int(round(sample_time * 1_000_000_000.0))}
    sample["aerosim_identity"] = {"vehicle_name": String(stream.vehicle_name)}
    return sample


func _sample_imu(state: Dictionary, sample_time: float) -> Dictionary:
    var kinematics: Dictionary = state.get("kinematics_estimated", {})
    var native_sample: Dictionary = state.get("imu_sample", {})
    return {
        "time_stamp": _timestamp(sample_time),
        "orientation": native_sample.get("orientation", kinematics.get("orientation", _quat(1.0, 0.0, 0.0, 0.0))).duplicate(true),
        "angular_velocity": native_sample.get("gyro", kinematics.get("angular_velocity", _vec3(0.0, 0.0, 0.0))).duplicate(true),
        "linear_acceleration": native_sample.get("accel", kinematics.get("linear_acceleration", _vec3(0.0, 0.0, 0.0))).duplicate(true),
    }


func _sample_gps(state: Dictionary, sample_time: float) -> Dictionary:
    var kinematics: Dictionary = state.get("kinematics_estimated", {})
    var position := _from_vec3(kinematics.get("position", _vec3(0.0, 0.0, 0.0)))
    var velocity: Dictionary = kinematics.get("linear_velocity", _vec3(0.0, 0.0, 0.0))
    var latitude := float(_origin.get("Latitude", 0.0))
    var longitude := float(_origin.get("Longitude", 0.0))
    var latitude_radians := deg_to_rad(latitude)
    var gps_latitude := latitude + rad_to_deg(position.x / EARTH_RADIUS_M)
    var gps_longitude := longitude + rad_to_deg(position.y / (EARTH_RADIUS_M * maxf(cos(latitude_radians), 0.01)))
    return {
        "time_stamp": _timestamp(sample_time),
        "gnss": {
            "geo_point": {"latitude": gps_latitude, "longitude": gps_longitude, "altitude": float(_origin.get("Altitude", 0.0)) - position.z},
            "eph": 0.1,
            "epv": 0.1,
            "velocity": velocity.duplicate(true),
            "fix_type": 3,
            "time_utc": int(round(sample_time * 1_000_000.0)),
        },
        "is_valid": true,
    }


func _sample_magnetometer(state: Dictionary, sample_time: float) -> Dictionary:
    var kinematics: Dictionary = state.get("kinematics_estimated", {})
    var orientation := _from_quat(kinematics.get("orientation", _quat(1.0, 0.0, 0.0, 0.0)))
    var body_field := orientation.inverse() * MAGNETIC_FIELD_NED_GAUSS
    return {
        "time_stamp": _timestamp(sample_time),
        "magnetic_field_body": _vec3(
            body_field.x + _deterministic_noise(sample_time, 1, MAGNETOMETER_NOISE_GAUSS),
            body_field.y + _deterministic_noise(sample_time, 2, MAGNETOMETER_NOISE_GAUSS),
            body_field.z + _deterministic_noise(sample_time, 3, MAGNETOMETER_NOISE_GAUSS)),
        "magnetic_field_covariance": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    }


func _sample_barometer(state: Dictionary, sample_time: float) -> Dictionary:
    var kinematics: Dictionary = state.get("kinematics_estimated", {})
    var position := _from_vec3(kinematics.get("position", _vec3(0.0, 0.0, 0.0)))
    var native_sample: Dictionary = state.get("imu_sample", {})
    var relative_altitude := float(native_sample.get("barometer_altitude_m", -position.z))
    var altitude := float(_origin.get("Altitude", 0.0)) + relative_altitude
    var pressure := 101325.0 * pow(maxf(1.0 - altitude / 44330.0, 0.01), 5.25588)
    return {
        "time_stamp": _timestamp(sample_time),
        "altitude": altitude,
        "pressure": pressure + _deterministic_noise(sample_time, 4, BAROMETER_PRESSURE_NOISE_PA),
        "temperature": BAROMETER_TEMPERATURE_C + _deterministic_noise(sample_time, 5, BAROMETER_TEMPERATURE_NOISE_C),
        "qnh": 1013.25,
    }


func _deterministic_noise(sample_time: float, channel: int, amplitude: float) -> float:
    var sample_index := int(round(sample_time * 50.0))
    return sin(float(sample_index) * 12.9898 + float(channel) * 78.233 + DETERMINISTIC_NOISE_SEED) * amplitude


func _sample_lidar(stream: Dictionary, state: Dictionary, sample_time: float) -> Dictionary:
    var kinematics: Dictionary = state.get("kinematics_estimated", {})
    var position := _from_vec3(kinematics.get("position", _vec3(0.0, 0.0, 0.0)))
    var vehicle_orientation := _from_quat(kinematics.get("orientation", _quat(1.0, 0.0, 0.0, 0.0)))
    var sensor_origin := position + vehicle_orientation * _from_vec3(stream.mount_position)
    var sensor_orientation := vehicle_orientation * _from_quat(stream.mount_orientation)
    var point_cloud := PackedFloat32Array()
    var segmentation := []
    for ray in [Vector3(0.0, 0.0, 1.0), Vector3(0.2, 0.0, 1.0), Vector3(-0.2, 0.0, 1.0), Vector3(0.0, 0.2, 1.0)]:
        var world_ray: Vector3 = (sensor_orientation * ray).normalized()
        if world_ray.z <= 0.000001:
            continue
        var distance: float = -sensor_origin.z / world_ray.z
        if distance < 0.0:
            continue
        var hit: Vector3 = sensor_origin + world_ray * distance
        var local_hit: Vector3 = sensor_orientation.inverse() * (hit - sensor_origin)
        point_cloud.append(local_hit.x)
        point_cloud.append(local_hit.y)
        point_cloud.append(local_hit.z)
        segmentation.append(0)
    return {
        "time_stamp": _timestamp(sample_time),
        "point_cloud": point_cloud,
        "pose": {"position": _vec3(sensor_origin.x, sensor_origin.y, sensor_origin.z), "orientation": _quat(sensor_orientation.w, sensor_orientation.x, sensor_orientation.y, sensor_orientation.z)},
        "segmentation": segmentation,
    }


func _timestamp(sample_time: float) -> int:
    return int(round(sample_time * 1_000_000_000.0))


func _vec3(x: float, y: float, z: float) -> Dictionary:
    return {"x_val": x, "y_val": y, "z_val": z}


func _quat(w: float, x: float, y: float, z: float) -> Dictionary:
    return {"w_val": w, "x_val": x, "y_val": y, "z_val": z}


func _mount_orientation(sensor: Dictionary) -> Dictionary:
    var euler := Vector3(
        deg_to_rad(float(sensor.get("Roll", 0.0))),
        deg_to_rad(float(sensor.get("Pitch", 0.0))),
        deg_to_rad(float(sensor.get("Yaw", 0.0)))
    )
    var orientation := Quaternion.from_euler(euler)
    return _quat(orientation.w, orientation.x, orientation.y, orientation.z)


func _from_vec3(value: Dictionary) -> Vector3:
    return Vector3(float(value.get("x_val", 0.0)), float(value.get("y_val", 0.0)), float(value.get("z_val", 0.0)))


func _from_quat(value: Dictionary) -> Quaternion:
    return Quaternion(float(value.get("x_val", 0.0)), float(value.get("y_val", 0.0)), float(value.get("z_val", 0.0)), float(value.get("w_val", 1.0))).normalized()
