class_name AirSimSettings
extends RefCounted

const DEFAULT_API_SERVER_PORT: int = 41451
const SUPPORTED_SIM_MODE := "Multirotor"
const SUPPORTED_CLOCK_TYPES := ["", "SteppableClock", "ScalableClock"]
const SUPPORTED_VEHICLE_TYPES := ["SimpleFlight", "PX4Multirotor"]

const ROOT_KEYS := {
    "SettingsVersion": true,
    "SimMode": true,
    "ClockType": true,
    "ClockSpeed": true,
    "ApiServerPort": true,
    "RpcEnabled": true,
    "OriginGeopoint": true,
    "Vehicles": true,
    "SubWindows": true,
    "Recording": true,
}

const ORIGIN_KEYS := {
    "Latitude": true,
    "Longitude": true,
    "Altitude": true,
}

const VEHICLE_KEYS := {
    "VehicleType": true,
    "Cameras": true,
    "Sensors": true,
}

const RECORDING_KEYS := {
    "RecordOnMove": true,
    "RecordInterval": true,
    "Folder": true,
    "Enabled": true,
}

const CAMERA_KEYS := {
    "X": true,
    "Y": true,
    "Z": true,
    "Roll": true,
    "Pitch": true,
    "Yaw": true,
    "Gimbal": true,
    "CaptureSettings": true,
    "NoiseSettings": true,
}

const GIMBAL_KEYS := {
    "Stabilization": true,
    "Pitch": true,
    "Roll": true,
    "Yaw": true,
}

const CAPTURE_KEYS := {
    "ImageType": true,
    "Width": true,
    "Height": true,
    "FOV_Degrees": true,
    "AutoExposureSpeed": true,
    "AutoExposureBias": true,
    "AutoExposureMaxBrightness": true,
    "AutoExposureMinBrightness": true,
    "MotionBlurAmount": true,
    "TargetGamma": true,
    "ProjectionMode": true,
    "OrthoWidth": true,
}

const NOISE_KEYS := {
    "Enabled": true,
    "ImageType": true,
    "RandContrib": true,
    "RandSpeed": true,
    "RandSize": true,
    "RandDensity": true,
    "HorzWaveContrib": true,
    "HorzWaveStrength": true,
    "HorzWaveVertSize": true,
    "HorzWaveScreenSize": true,
    "HorzNoiseLinesContrib": true,
    "HorzNoiseLinesDensityY": true,
    "HorzNoiseLinesDensityXY": true,
    "HorzDistortionContrib": true,
    "HorzDistortionStrength": true,
}

const SENSOR_KEYS := {
    "SensorType": true,
    "Enabled": true,
    "X": true,
    "Y": true,
    "Z": true,
    "Roll": true,
    "Pitch": true,
    "Yaw": true,
    "DrawDebugPoints": true,
    "DataFrame": true,
    "UpdateFrequency": true,
    "UpdateLatency": true,
    "StartupDelay": true,
}

const SUBWINDOW_KEYS := {
    "WindowID": true,
    "ImageType": true,
    "Visible": true,
    "CameraName": true,
    "CameraID": true,
    "VehicleName": true,
    "External": true,
}


static func validate(raw: Dictionary) -> Dictionary:
    var errors: Array[String] = []
    var settings := raw.duplicate(true)
    var manifest_result := _load_manifest()
    if not manifest_result.ok:
        return {
            "ok": false,
            "settings": settings,
            "error": manifest_result.error,
            "errors": [manifest_result.error],
        }
    var manifest: Dictionary = manifest_result.manifest
    var schema: Dictionary = manifest["schema"]

    settings["SimMode"] = raw.get("SimMode", SUPPORTED_SIM_MODE)
    settings["ClockType"] = raw.get("ClockType", "")
    settings["ClockSpeed"] = raw.get("ClockSpeed", 1.0)
    settings["ApiServerPort"] = raw.get("ApiServerPort", DEFAULT_API_SERVER_PORT)
    settings["RpcEnabled"] = raw.get("RpcEnabled", true)
    if _is_integer_number(settings["ApiServerPort"]):
        settings["ApiServerPort"] = int(settings["ApiServerPort"])

    _reject_unknown_keys(raw, _manifest_keys(manifest, "root"), "root", errors)
    for required_key in schema["required"]:
        if not raw.has(required_key):
            errors.append("%s is required" % required_key)
    _validate_manifest_types(raw, schema.get("types", {}), errors)
    _validate_settings_version(raw, errors, float(manifest["settings_version"]))
    _validate_sim_mode(raw, errors, _manifest_enum(schema, "SimMode"))
    _validate_clock(raw, errors, _manifest_enum(schema, "ClockType"))
    _validate_rpc(raw, errors)
    _validate_origin(raw, errors, _manifest_keys(manifest, "origin_geopoint"), manifest)
    _validate_vehicles(raw, errors, manifest)
    _validate_subwindows(raw, errors, _manifest_keys(manifest, "subwindow"), manifest)
    _validate_recording(raw, errors, _manifest_keys(manifest, "recording"), manifest)

    var result := {
        "ok": errors.is_empty(),
        "settings": settings,
        "error": "; ".join(errors),
        "errors": errors,
    }
    return result


static func validate_vehicle_names(vehicle_names: Array) -> Dictionary:
    var errors: Array[String] = []
    var seen := {}
    for value in vehicle_names:
        if typeof(value) != TYPE_STRING or String(value).is_empty():
            errors.append("vehicle names must be non-empty strings")
            continue
        var name := String(value)
        if seen.has(name):
            errors.append("duplicate vehicle name: %s" % name)
        seen[name] = true
    return {"ok": errors.is_empty(), "error": "; ".join(errors), "errors": errors}


static func validate_vehicle_name(requested_name: Variant, vehicle_names: Array) -> Dictionary:
    if typeof(requested_name) != TYPE_STRING or String(requested_name).is_empty():
        return {"ok": false, "error": "vehicle_name is required and must be non-empty"}
    var names_result := validate_vehicle_names(vehicle_names)
    if not names_result.ok:
        return names_result
    var name := String(requested_name)
    if not vehicle_names.has(name):
        return {"ok": false, "error": "unknown vehicle: %s" % name}
    return {"ok": true, "name": name}


static func _reject_unknown_keys(value: Dictionary, allowed: Dictionary, scope: String, errors: Array[String]) -> void:
    for key in value.keys():
        var key_name := String(key)
        if not allowed.has(key_name):
            errors.append("unsupported %s setting '%s'" % [scope, key_name])


static func _load_manifest() -> Dictionary:
    var file := FileAccess.open("res://config/airsim_compatibility_manifest.json", FileAccess.READ)
    if file == null:
        return {"ok": false, "error": "AirSim compatibility manifest is unavailable"}
    var manifest = JSON.parse_string(file.get_as_text())
    if typeof(manifest) != TYPE_DICTIONARY:
        return {"ok": false, "error": "AirSim compatibility manifest must be an object"}
    if manifest.get("manifest_version") != 1 or not _is_finite_number(manifest.get("settings_version")):
        return {"ok": false, "error": "AirSim compatibility manifest has an unsupported version"}
    if typeof(manifest.get("settings")) != TYPE_DICTIONARY:
        return {"ok": false, "error": "AirSim compatibility manifest has no settings schema"}
    if typeof(manifest.get("schema")) != TYPE_DICTIONARY:
        return {"ok": false, "error": "AirSim compatibility manifest has no type schema"}
    var schema: Dictionary = manifest["schema"]
    if typeof(schema.get("types")) != TYPE_DICTIONARY or typeof(schema.get("nested_types")) != TYPE_DICTIONARY or typeof(schema.get("required")) != TYPE_ARRAY or typeof(schema.get("enums")) != TYPE_DICTIONARY:
        return {"ok": false, "error": "AirSim compatibility manifest type schema is malformed"}
    for key in manifest["settings"].get("root", []):
        if not schema["types"].has(key):
            return {"ok": false, "error": "AirSim compatibility manifest has no type for '%s'" % key}
    for section in ["origin_geopoint", "vehicle", "camera", "sensor", "gimbal", "capture_settings", "noise_settings", "subwindow", "recording"]:
        var section_types: Dictionary = schema["nested_types"].get(section, {})
        for key in manifest["settings"].get(section, []):
            if not section_types.has(key):
                return {"ok": false, "error": "AirSim compatibility manifest has no type for '%s.%s'" % [section, key]}
    return {"ok": true, "manifest": manifest}


static func _manifest_keys(manifest: Dictionary, section: String) -> Dictionary:
    var keys := {}
    var values = manifest["settings"].get(section, [])
    if typeof(values) != TYPE_ARRAY:
        return keys
    for value in values:
        keys[String(value)] = true
    return keys


static func _manifest_enum(schema: Dictionary, field: String) -> Array:
    var enums: Dictionary = schema.get("enums", {})
    var values = enums.get(field, [])
    return values if typeof(values) == TYPE_ARRAY else []


static func _validate_manifest_types(raw: Dictionary, types: Dictionary, errors: Array[String]) -> void:
    for key in raw:
        if not types.has(key):
            continue
        var expected: String = types[key]
        if not _manifest_type_matches(raw[key], expected):
            errors.append("%s must be a %s" % [key, expected])


static func _validate_manifest_entry_types(value: Dictionary, schema: Dictionary, section: String, scope: String, errors: Array[String]) -> void:
    var nested_types: Dictionary = schema["nested_types"]
    var types: Dictionary = nested_types.get(section, {})
    for key in value:
        if types.has(key) and not _manifest_type_matches(value[key], types[key]):
            errors.append("%s.%s must be a %s" % [scope, key, types[key]])


static func _manifest_type_matches(value: Variant, expected: String) -> bool:
    match expected:
        "number": return _is_finite_number(value)
        "integer": return _is_integer_number(value)
        "string": return typeof(value) == TYPE_STRING
        "boolean": return typeof(value) == TYPE_BOOL
        "object": return typeof(value) == TYPE_DICTIONARY
        "array": return typeof(value) == TYPE_ARRAY
        _:
            return false


static func _validate_settings_version(raw: Dictionary, errors: Array[String], expected: float) -> void:
    if not raw.has("SettingsVersion"):
        return
    elif not _is_finite_number(raw["SettingsVersion"]) or float(raw["SettingsVersion"]) != expected:
        errors.append("SettingsVersion must be numeric %s" % expected)


static func _validate_sim_mode(raw: Dictionary, errors: Array[String], allowed: Array) -> void:
    if raw.has("SimMode") and (typeof(raw["SimMode"]) != TYPE_STRING or not allowed.has(raw["SimMode"])):
        errors.append("SimMode must be one of %s" % ", ".join(allowed))


static func _validate_clock(raw: Dictionary, errors: Array[String], allowed: Array) -> void:
    if raw.has("ClockType") and (typeof(raw["ClockType"]) != TYPE_STRING or not allowed.has(raw["ClockType"])):
        errors.append("ClockType must be one of %s" % ", ".join(allowed))
    if raw.has("ClockSpeed") and (not _is_finite_number(raw["ClockSpeed"]) or float(raw["ClockSpeed"]) <= 0.0):
        errors.append("ClockSpeed must be a positive number")


static func _validate_rpc(raw: Dictionary, errors: Array[String]) -> void:
    if raw.has("RpcEnabled") and typeof(raw["RpcEnabled"]) != TYPE_BOOL:
        errors.append("RpcEnabled must be boolean")
    if raw.has("ApiServerPort"):
        var port = raw["ApiServerPort"]
        if not _is_integer_number(port) or int(port) < 1 or int(port) > 65535:
            errors.append("ApiServerPort must be an integer from 1 to 65535")


static func _validate_origin(raw: Dictionary, errors: Array[String], allowed: Dictionary, manifest: Dictionary) -> void:
    if not raw.has("OriginGeopoint"):
        return
    if typeof(raw["OriginGeopoint"]) != TYPE_DICTIONARY:
        errors.append("OriginGeopoint must be an object")
        return
    var origin: Dictionary = raw["OriginGeopoint"]
    _reject_unknown_keys(origin, allowed, "OriginGeopoint", errors)
    _validate_manifest_entry_types(origin, manifest["schema"], "origin_geopoint", "OriginGeopoint", errors)
    for key in allowed:
        if not origin.has(key) or not _is_finite_number(origin[key]):
            errors.append("OriginGeopoint.%s must be numeric" % key)


static func _validate_vehicles(raw: Dictionary, errors: Array[String], manifest: Dictionary) -> void:
    if not raw.has("Vehicles"):
        return
    if typeof(raw["Vehicles"]) != TYPE_DICTIONARY:
        errors.append("Vehicles must be an object")
        return
    var vehicles: Dictionary = raw["Vehicles"]
    var supported_vehicle_types := _manifest_enum(manifest["schema"], "VehicleType")
    if vehicles.is_empty() or vehicles.size() > 2:
        errors.append("Vehicles must contain one or two named vehicles")
    var vehicle_names: Array = []
    for vehicle_name in vehicles.keys():
        vehicle_names.append(vehicle_name)
    var vehicle_name_result := validate_vehicle_names(vehicle_names)
    errors.append_array(vehicle_name_result.errors)
    for vehicle_name in vehicles:
        var vehicle = vehicles[vehicle_name]
        if typeof(vehicle) != TYPE_DICTIONARY:
            errors.append("Vehicles.%s must be an object" % vehicle_name)
            continue
        if typeof(vehicle_name) != TYPE_STRING or String(vehicle_name).is_empty():
            errors.append("vehicle names must be non-empty strings")
            continue
        var vehicle_dict: Dictionary = vehicle
        _reject_unknown_keys(vehicle_dict, _manifest_keys(manifest, "vehicle"), "vehicle %s" % vehicle_name, errors)
        _validate_manifest_entry_types(vehicle_dict, manifest["schema"], "vehicle", "Vehicles.%s" % vehicle_name, errors)
        if not vehicle_dict.has("VehicleType") or typeof(vehicle_dict["VehicleType"]) != TYPE_STRING or not supported_vehicle_types.has(vehicle_dict["VehicleType"]):
            errors.append("Vehicles.%s.VehicleType must be one of %s" % [vehicle_name, ", ".join(supported_vehicle_types)])
        elif vehicle_dict["VehicleType"] == "PX4Multirotor":
            _validate_px4_transport(vehicle_dict, "Vehicles.%s" % vehicle_name, errors)
        for collection_name in ["Cameras", "Sensors"]:
            if not vehicle_dict.has(collection_name):
                continue
            if typeof(vehicle_dict[collection_name]) != TYPE_DICTIONARY:
                errors.append("Vehicles.%s.%s must be an object" % [vehicle_name, collection_name])
                continue
            var scope := "vehicle %s %s" % [vehicle_name, collection_name]
            var section := "camera" if collection_name == "Cameras" else "sensor"
            var allowed := _manifest_keys(manifest, section)
            _validate_named_entries(vehicle_dict[collection_name], allowed, scope, errors, collection_name == "Cameras", manifest)


static func _validate_px4_transport(vehicle: Dictionary, scope: String, errors: Array[String]) -> void:
    if vehicle.get("UseSerial", false):
        errors.append("%s.UseSerial is unsupported; PX4 SITL requires UDP/TCP transport" % scope)
    for key in ["TcpPort", "ControlPortLocal", "ControlPortRemote", "UdpPort"]:
        if vehicle.has(key) and (not _is_integer_number(vehicle[key]) or int(vehicle[key]) < 1 or int(vehicle[key]) > 65535):
            errors.append("%s.%s must be an integer from 1 to 65535" % [scope, key])
    for key in ["ControlIp", "LocalHostIp", "UdpIp"]:
        if vehicle.has(key) and (typeof(vehicle[key]) != TYPE_STRING or String(vehicle[key]).is_empty()):
            errors.append("%s.%s must be a non-empty string" % [scope, key])
    if vehicle.has("HardwarePreset") and (typeof(vehicle["HardwarePreset"]) != TYPE_STRING or not String(vehicle["HardwarePreset"]).begins_with("res://config/drones/")):
        errors.append("%s.HardwarePreset must be a drone preset resource path" % scope)
    if vehicle.has("HilGpsIntervalSeconds") and (not _is_finite_number(vehicle["HilGpsIntervalSeconds"]) or float(vehicle["HilGpsIntervalSeconds"]) < 0.0):
        errors.append("%s.HilGpsIntervalSeconds must be finite and non-negative" % scope)
    if vehicle.has("HilActuatorQuadXOrder"):
        var motor_order: Variant = vehicle["HilActuatorQuadXOrder"]
        var motor_names := {}
        if not motor_order is Array or motor_order.size() != 4:
            errors.append("%s.HilActuatorQuadXOrder must name four distinct motors" % scope)
        else:
            for motor_name_value in motor_order:
                if typeof(motor_name_value) != TYPE_STRING or String(motor_name_value).is_empty() or motor_names.has(String(motor_name_value)):
                    errors.append("%s.HilActuatorQuadXOrder must name four distinct motors" % scope)
                    break
                motor_names[String(motor_name_value)] = true


static func _validate_named_entries(value: Dictionary, allowed: Dictionary, scope: String, errors: Array[String], is_camera: bool, manifest: Dictionary) -> void:
    for entry_name in value:
        if typeof(entry_name) != TYPE_STRING or String(entry_name).is_empty():
            errors.append("%s names must be non-empty strings" % scope)
            continue
        var entry = value[entry_name]
        if typeof(entry) != TYPE_DICTIONARY:
            errors.append("%s.%s must be an object" % [scope, entry_name])
            continue
        var entry_scope := "%s.%s" % [scope, entry_name]
        _reject_unknown_keys(entry, allowed, entry_scope, errors)
        if is_camera:
            _validate_camera_entry(entry, entry_scope, errors, manifest)
        else:
            _validate_manifest_entry_types(entry, manifest["schema"], "sensor", entry_scope, errors)
            _validate_sensor_entry(entry, entry_scope, errors)


static func _validate_camera_entry(value: Dictionary, scope: String, errors: Array[String], manifest: Dictionary) -> void:
    _validate_numeric_fields(value, ["X", "Y", "Z", "Roll", "Pitch", "Yaw"], scope, errors)
    if value.has("Gimbal"):
        if typeof(value["Gimbal"]) != TYPE_DICTIONARY:
            errors.append("%s.Gimbal must be an object" % scope)
        else:
            var gimbal: Dictionary = value["Gimbal"]
            _reject_unknown_keys(gimbal, _manifest_keys(manifest, "gimbal"), "%s.Gimbal" % scope, errors)
            _validate_manifest_entry_types(gimbal, manifest["schema"], "gimbal", "%s.Gimbal" % scope, errors)
            _validate_numeric_fields(gimbal, ["Stabilization", "Pitch", "Roll", "Yaw"], "%s.Gimbal" % scope, errors)
    _validate_manifest_entry_types(value, manifest["schema"], "camera", scope, errors)
    _validate_camera_list(value, "CaptureSettings", _manifest_keys(manifest, "capture_settings"), scope, errors, manifest)
    _validate_camera_list(value, "NoiseSettings", _manifest_keys(manifest, "noise_settings"), scope, errors, manifest)


static func _validate_camera_list(value: Dictionary, key: String, allowed: Dictionary, scope: String, errors: Array[String], manifest: Dictionary) -> void:
    if not value.has(key):
        return
    if typeof(value[key]) != TYPE_ARRAY:
        errors.append("%s.%s must be an array" % [scope, key])
        return
    for index in value[key].size():
        var item = value[key][index]
        var item_scope := "%s.%s[%d]" % [scope, key, index]
        if typeof(item) != TYPE_DICTIONARY:
            errors.append("%s must be an object" % item_scope)
            continue
        var item_dict: Dictionary = item
        _reject_unknown_keys(item_dict, allowed, item_scope, errors)
        _validate_manifest_entry_types(item_dict, manifest["schema"], "capture_settings" if key == "CaptureSettings" else "noise_settings", item_scope, errors)
        if key == "CaptureSettings":
            if item_dict.has("ImageType") and not _is_integer_number(item_dict["ImageType"]):
                errors.append("%s.ImageType must be an integer" % item_scope)
            for field in ["Width", "Height"]:
                if item_dict.has(field) and not _is_integer_number(item_dict[field]):
                    errors.append("%s.%s must be an integer" % [item_scope, field])
            _validate_numeric_fields(item_dict, ["FOV_Degrees", "AutoExposureSpeed", "AutoExposureBias", "AutoExposureMaxBrightness", "AutoExposureMinBrightness", "MotionBlurAmount", "TargetGamma", "OrthoWidth"], item_scope, errors)
            if item_dict.has("ProjectionMode") and typeof(item_dict["ProjectionMode"]) != TYPE_STRING:
                errors.append("%s.ProjectionMode must be a string" % item_scope)
        else:
            if item_dict.has("Enabled") and typeof(item_dict["Enabled"]) != TYPE_BOOL:
                errors.append("%s.Enabled must be boolean" % item_scope)
            if item_dict.has("ImageType") and not _is_integer_number(item_dict["ImageType"]):
                errors.append("%s.ImageType must be an integer" % item_scope)
            _validate_numeric_fields(item_dict, ["RandContrib", "RandSpeed", "RandSize", "RandDensity", "HorzWaveContrib", "HorzWaveStrength", "HorzWaveVertSize", "HorzWaveScreenSize", "HorzNoiseLinesContrib", "HorzNoiseLinesDensityY", "HorzNoiseLinesDensityXY", "HorzDistortionContrib", "HorzDistortionStrength"], item_scope, errors)


static func _validate_sensor_entry(value: Dictionary, scope: String, errors: Array[String]) -> void:
    if not value.has("SensorType"):
        errors.append("%s.SensorType is required" % scope)
    elif not _is_integer_number(value["SensorType"]):
        errors.append("%s.SensorType must be an integer" % scope)
    elif not [1, 2, 3, 4, 6].has(int(value["SensorType"])):
        errors.append("%s.SensorType is unsupported" % scope)
    for key in ["Enabled", "DrawDebugPoints"]:
        if value.has(key) and typeof(value[key]) != TYPE_BOOL:
            errors.append("%s.%s must be boolean" % [scope, key])
    if value.has("DataFrame") and typeof(value["DataFrame"]) != TYPE_STRING:
        errors.append("%s.DataFrame must be a string" % scope)
    if value.has("UpdateFrequency") and (not _is_finite_number(value["UpdateFrequency"]) or float(value["UpdateFrequency"]) <= 0.0):
        errors.append("%s.UpdateFrequency must be positive" % scope)
    for key in ["UpdateLatency", "StartupDelay"]:
        if value.has(key) and (not _is_finite_number(value[key]) or float(value[key]) < 0.0):
            errors.append("%s.%s must not be negative" % [scope, key])
    _validate_numeric_fields(value, ["X", "Y", "Z", "Roll", "Pitch", "Yaw"], scope, errors)


static func _validate_numeric_fields(value: Dictionary, fields: Array, scope: String, errors: Array[String]) -> void:
    for field in fields:
        if value.has(field) and not _is_finite_number(value[field]):
            errors.append("%s.%s must be numeric" % [scope, field])


static func _is_finite_number(value: Variant) -> bool:
    return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value))


static func _is_integer_number(value: Variant) -> bool:
    return _is_finite_number(value) and is_equal_approx(float(value), roundf(float(value)))


static func _validate_subwindows(raw: Dictionary, errors: Array[String], allowed: Dictionary, manifest: Dictionary) -> void:
    if not raw.has("SubWindows"):
        return
    if typeof(raw["SubWindows"]) != TYPE_ARRAY:
        errors.append("SubWindows must be an array")
        return
    for index in raw["SubWindows"].size():
        var subwindow = raw["SubWindows"][index]
        if typeof(subwindow) != TYPE_DICTIONARY:
            errors.append("SubWindows[%d] must be an object" % index)
            continue
        var value: Dictionary = subwindow
        _reject_unknown_keys(value, allowed, "SubWindows[%d]" % index, errors)
        _validate_manifest_entry_types(value, manifest["schema"], "subwindow", "SubWindows[%d]" % index, errors)
        if value.has("WindowID") and not _is_integer_number(value["WindowID"]):
            errors.append("SubWindows[%d].WindowID must be an integer" % index)
        if value.has("ImageType") and not _is_integer_number(value["ImageType"]):
            errors.append("SubWindows[%d].ImageType must be an integer" % index)
        for key in ["Visible", "External"]:
            if value.has(key) and typeof(value[key]) != TYPE_BOOL:
                errors.append("SubWindows[%d].%s must be boolean" % [index, key])
        for key in ["CameraName", "VehicleName"]:
            if value.has(key) and typeof(value[key]) != TYPE_STRING:
                errors.append("SubWindows[%d].%s must be a string" % [index, key])
        if value.has("CameraID") and not _is_integer_number(value["CameraID"]):
            errors.append("SubWindows[%d].CameraID must be an integer" % index)


static func _validate_recording(raw: Dictionary, errors: Array[String], allowed: Dictionary, manifest: Dictionary) -> void:
    if not raw.has("Recording"):
        return
    if typeof(raw["Recording"]) != TYPE_DICTIONARY:
        errors.append("Recording must be an object")
        return
    var recording: Dictionary = raw["Recording"]
    _reject_unknown_keys(recording, allowed, "Recording", errors)
    _validate_manifest_entry_types(recording, manifest["schema"], "recording", "Recording", errors)
    for key in ["RecordOnMove", "Enabled"]:
        if recording.has(key) and typeof(recording[key]) != TYPE_BOOL:
            errors.append("Recording.%s must be boolean" % key)
    if recording.has("RecordInterval") and (not _is_finite_number(recording["RecordInterval"]) or float(recording["RecordInterval"]) < 0.0):
        errors.append("Recording.RecordInterval must be a non-negative number")
    if recording.has("Folder") and typeof(recording["Folder"]) != TYPE_STRING:
        errors.append("Recording.Folder must be a string")
