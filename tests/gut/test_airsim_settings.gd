extends GutTest

const AirSimSettings = preload("res://common/rpc/airsim_settings.gd")


func test_accepts_frozen_multirotor_settings_subset() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ClockType": "SteppableClock",
        "ClockSpeed": 1.0,
        "ApiServerPort": 41451,
        "RpcEnabled": true,
        "OriginGeopoint": {"Latitude": 25.0, "Longitude": 121.0, "Altitude": 10.0},
        "Vehicles": {
            "Drone1": {"VehicleType": "SimpleFlight", "Cameras": {}, "Sensors": {}}
        },
        "SubWindows": [],
        "Recording": {"Enabled": false}
    })

    assert_true(result.ok, "The frozen multirotor settings subset must be accepted.")
    assert_eq(result.settings["ApiServerPort"], 41451)
    assert_eq(result.settings["Vehicles"]["Drone1"]["VehicleType"], "SimpleFlight")


func test_rejects_unknown_root_setting_instead_of_silently_ignoring_it() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "FutureSetting": true
    })

    assert_false(result.ok, "Unknown root settings must fail loudly.")
    assert_string_contains(result.error, "FutureSetting")


func test_vehicle_name_validation_rejects_duplicate_empty_missing_and_unknown_names() -> void:
    var duplicate := AirSimSettings.validate_vehicle_names(["DroneA", "DroneA"])
    assert_false(duplicate.ok)
    assert_string_contains(duplicate.error, "duplicate")

    var invalid := AirSimSettings.validate_vehicle_names(["DroneA", ""])
    assert_false(invalid.ok)
    assert_string_contains(invalid.error, "non-empty")

    var missing := AirSimSettings.validate_vehicle_name("", ["DroneA", "DroneB"])
    assert_false(missing.ok)
    assert_string_contains(missing.error, "required")

    var unknown := AirSimSettings.validate_vehicle_name("DroneC", ["DroneA", "DroneB"])
    assert_false(unknown.ok)
    assert_string_contains(unknown.error, "unknown")


func test_rejects_unsupported_vehicle_type_and_more_than_two_vehicles() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {"VehicleType": "PhysXCar"},
            "Drone2": {"VehicleType": "SimpleFlight"},
            "Drone3": {"VehicleType": "PX4Multirotor"}
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "one or two")
    assert_string_contains(result.error, "SimpleFlight, PX4Multirotor")


func test_applies_the_loopback_rpc_port_default() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor"
    })

    assert_true(result.ok)
    assert_eq(result.settings["ApiServerPort"], AirSimSettings.DEFAULT_API_SERVER_PORT)
    assert_eq(result.settings["RpcEnabled"], true)


func test_startup_settings_are_deep_copied_and_not_player_persisted() -> void:
    var source := {
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight"}}
    }
    var result := AirSimSettings.validate(source)

    assert_true(result.ok)
    result.settings["Vehicles"]["Drone1"]["VehicleType"] = "PX4Multirotor"
    assert_eq(source["Vehicles"]["Drone1"]["VehicleType"], "SimpleFlight")


func test_rejects_unknown_recording_field() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Recording": {"Enabled": false, "FutureField": true}
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "FutureField")


func test_rejects_unknown_nested_camera_field() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "SimpleFlight",
                "Cameras": {"front_center": {"FutureField": true}}
            }
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "FutureField")


func test_rejects_unknown_nested_capture_field() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "SimpleFlight",
                "Cameras": {"front_center": {"CaptureSettings": [{"FutureField": true}]}}
            }
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "FutureField")


func test_rejects_invalid_nested_noise_and_sensor_parameter_types() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "SimpleFlight",
                "Cameras": {"front_center": {"NoiseSettings": [{"Enabled": "yes"}]}},
                "Sensors": {"imu": {"SensorType": 6, "Parameters": {"NoiseSigma": "nope"}}}
            }
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "NoiseSettings")
    assert_string_contains(result.error, "Parameters")


func test_rejects_named_sensor_without_a_sensor_type() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "SimpleFlight",
                "Sensors": {"gps": {"Enabled": true}}
            }
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "SensorType is required")


func test_rejects_invalid_subwindow_and_recording_types() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "SubWindows": [{"WindowID": "one"}],
        "Recording": {"Enabled": "yes", "RecordInterval": -1.0}
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "WindowID")
    assert_string_contains(result.error, "Recording.Enabled")
    assert_string_contains(result.error, "RecordInterval")


func test_accepts_px4_sitl_transport_settings() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ClockType": "SteppableClock",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "PX4Multirotor",
                "UseSerial": false,
                "UseTcp": true,
                "TcpPort": 4560,
                "ControlIp": "127.0.0.1",
                "ControlPortLocal": 14540,
                "ControlPortRemote": 14580,
                "LockStep": true,
                "HilActuatorQuadXOrder": ["front_right", "rear_left", "front_left", "rear_right"],
                "LocalHostIp": "127.0.0.1",
                "UdpIp": "127.0.0.1",
                "UdpPort": 14560
            }
        }
    })

    assert_true(result.ok, result.error)
    assert_eq(result.settings["Vehicles"]["Drone1"]["TcpPort"], 4560)


func test_rejects_invalid_px4_quad_x_actuator_mapping() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "PX4Multirotor",
                "HilActuatorQuadXOrder": ["front_right", "front_right", "rear_left", "front_left"]
            }
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "HilActuatorQuadXOrder must name four distinct motors")


func test_rejects_px4_serial_transport_and_invalid_ports() -> void:
    var result := AirSimSettings.validate({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "Drone1": {
                "VehicleType": "PX4Multirotor",
                "UseSerial": true,
                "ControlPortLocal": 0,
                "ControlPortRemote": 70000
            }
        }
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "UseSerial")
    assert_string_contains(result.error, "ControlPortLocal")
    assert_string_contains(result.error, "ControlPortRemote")
