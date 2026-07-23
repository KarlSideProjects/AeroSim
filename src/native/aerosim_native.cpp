#include "aerosim_native.hpp"

#include "aerosim_aerodynamics.hpp"
#include "aerosim_probe.hpp"
#include <algorithm>
#include <cmath>
#include <godot_cpp/classes/hashing_context.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

namespace {

bool bool_value(const Dictionary &dict, const char *key, bool fallback) {
    return dict.has(key) ? static_cast<bool>(dict[key]) : fallback;
}

double double_value(const Dictionary &dict, const char *key, double fallback) {
    return dict.has(key) ? static_cast<double>(dict[key]) : fallback;
}

std::int32_t int_value(const Dictionary &dict, const char *key, std::int32_t fallback) {
    return dict.has(key) ? static_cast<std::int32_t>(dict[key]) : fallback;
}

aerosim::Vec3 vec3_value(const Dictionary &dict, const char *key, const aerosim::Vec3 &fallback) {
    if (!dict.has(key) || dict[key].get_type() != Variant::VECTOR3) {
        return fallback;
    }
    const Vector3 value = dict[key];
    return {value.x, value.y, value.z};
}

bool per_motor_model_value(const Dictionary &model, aerosim::PerMotorPhysicsConfig &per_motor) {
    static constexpr const char *required_scalars[] = {
            "max_thrust_per_motor_newtons",
            "max_current_per_motor_a",
            "yaw_torque_per_newton",
    };
    if (!model.has("inertia_frd") || model["inertia_frd"].get_type() != Variant::VECTOR3 ||
            !model.has("position_frd") || model["position_frd"].get_type() != Variant::ARRAY ||
            !model.has("spin_direction") || model["spin_direction"].get_type() != Variant::ARRAY) {
        return false;
    }
    for (const char *key : required_scalars) {
        if (!model.has(key) || (model[key].get_type() != Variant::FLOAT && model[key].get_type() != Variant::INT)) {
            return false;
        }
    }

    const Vector3 inertia = model["inertia_frd"];
    const Array positions = model["position_frd"];
    const Array spins = model["spin_direction"];
    if (positions.size() != 4 || spins.size() != 4) {
        return false;
    }
    per_motor.inertia_kg_m2 = {inertia.x, inertia.y, inertia.z};
    for (std::int32_t index = 0; index < 4; ++index) {
        if (positions[index].get_type() != Variant::VECTOR3 ||
                (spins[index].get_type() != Variant::FLOAT && spins[index].get_type() != Variant::INT)) {
            return false;
        }
        const Vector3 position = positions[index];
        per_motor.position_frd[static_cast<std::size_t>(index)] = {position.x, position.y, position.z};
        per_motor.spin_direction[static_cast<std::size_t>(index)] = static_cast<double>(spins[index]);
    }
    per_motor.max_thrust_per_motor_newtons = static_cast<double>(model["max_thrust_per_motor_newtons"]);
    per_motor.max_current_per_motor_a = static_cast<double>(model["max_current_per_motor_a"]);
    per_motor.yaw_torque_per_newton = static_cast<double>(model["yaw_torque_per_newton"]);
    return true;
}

String sha256_string(const String &value) {
    Ref<HashingContext> hashing = memnew(HashingContext);
    if (hashing->start(HashingContext::HASH_SHA256) != OK) {
        return {};
    }
    hashing->update(value.to_utf8_buffer());
    return hashing->finish().hex_encode();
}

bool simulation_config_manifest_value(
        const Dictionary &manifest,
        aerosim::SimulationConfig &config) {
    static constexpr const char *required_scalars[] = {
            "mass_kg", "gravity_mps2", "physics_hz", "substep_hz",
            "max_total_thrust_newtons", "hover_throttle", "motor_tau_s",
            "battery_nominal_voltage_v", "battery_cells", "battery_cell_resistance_ohm",
            "battery_remaining_mah", "max_total_current_a", "max_motor_rpm",
    };
    for (const char *key : required_scalars) {
        if (!manifest.has(key) || (manifest[key].get_type() != Variant::FLOAT &&
                manifest[key].get_type() != Variant::INT)) {
            return false;
        }
    }
    config.mass_kg = static_cast<double>(manifest["mass_kg"]);
    config.gravity_mps2 = static_cast<double>(manifest["gravity_mps2"]);
    config.physics_hz = static_cast<std::int32_t>(manifest["physics_hz"]);
    config.substep_hz = static_cast<std::int32_t>(manifest["substep_hz"]);
    config.max_total_thrust_newtons = static_cast<double>(manifest["max_total_thrust_newtons"]);
    config.hover_throttle = static_cast<double>(manifest["hover_throttle"]);
    config.motor_tau_s = static_cast<double>(manifest["motor_tau_s"]);
    config.battery_nominal_voltage_v = static_cast<double>(manifest["battery_nominal_voltage_v"]);
    config.battery_cells = static_cast<double>(manifest["battery_cells"]);
    config.battery_cell_resistance_ohm = static_cast<double>(manifest["battery_cell_resistance_ohm"]);
    config.battery_remaining_mah = static_cast<double>(manifest["battery_remaining_mah"]);
    config.max_total_current_a = static_cast<double>(manifest["max_total_current_a"]);
    config.max_motor_rpm = static_cast<double>(manifest["max_motor_rpm"]);
    const Variant per_motor_variant = manifest.get("per_motor", Variant());
    if (per_motor_variant.get_type() != Variant::DICTIONARY ||
            !per_motor_model_value(static_cast<Dictionary>(per_motor_variant), config.per_motor)) {
        return false;
    }
    const Variant a3_variant = manifest.get("a3_drag", Variant());
    if (a3_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary a3 = a3_variant;
        config.a3_drag.enabled = bool_value(a3, "enabled", config.a3_drag.enabled);
        config.a3_drag.coefficient = {
                double_value(a3, "coefficient_x_kg", config.a3_drag.coefficient.x),
                double_value(a3, "coefficient_y_kg", config.a3_drag.coefficient.y),
                double_value(a3, "coefficient_z_kg", config.a3_drag.coefficient.z),
        };
    }
    const Variant a6_variant = manifest.get("a6_propwash", Variant());
    if (a6_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary a6 = a6_variant;
        config.a6_propwash.enabled = bool_value(a6, "enabled", config.a6_propwash.enabled);
        config.a6_propwash.full_collective_angular_accel_rad_s2 = double_value(
                a6, "full_collective_angular_accel_rad_s2", config.a6_propwash.full_collective_angular_accel_rad_s2);
        config.a6_propwash.minimum_wake_entry_speed_mps = double_value(
                a6, "minimum_wake_entry_speed_mps", config.a6_propwash.minimum_wake_entry_speed_mps);
        config.a6_propwash.minimum_transverse_rate_rad_s = double_value(
                a6, "minimum_transverse_rate_rad_s", config.a6_propwash.minimum_transverse_rate_rad_s);
    }
    const Variant body_drag_variant = manifest.get("body_drag", Variant());
    if (body_drag_variant.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary body_drag = body_drag_variant;
    config.body_drag.enabled = bool_value(body_drag, "enabled", config.body_drag.enabled);
    config.body_drag.drag_coefficient = vec3_value(body_drag, "drag_coefficient", config.body_drag.drag_coefficient);
    config.body_drag.frontal_area_m2 = vec3_value(body_drag, "frontal_area_m2", config.body_drag.frontal_area_m2);
    config.body_drag.center_of_pressure_frd_m = vec3_value(
            body_drag, "center_of_pressure_frd_m", config.body_drag.center_of_pressure_frd_m);
    config.air_density_kg_m3 = double_value(body_drag, "air_density_kg_m3", config.air_density_kg_m3);
    if (manifest.has("external_force_world")) {
        config.external_force_world = vec3_value(manifest, "external_force_world", config.external_force_world);
    }
    const Variant a4_variant = manifest.get("a4_ground_effect", Variant());
    if (a4_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary a4 = a4_variant;
        config.a4_ground_effect.enabled = bool_value(a4, "enabled", config.a4_ground_effect.enabled);
        config.a4_ground_effect.kf = double_value(a4, "kf", config.a4_ground_effect.kf);
        config.a4_ground_effect.ground_effect_coeff = double_value(a4, "ground_effect_coeff", config.a4_ground_effect.ground_effect_coeff);
        config.a4_ground_effect.prop_radius_m = double_value(a4, "prop_radius_m", config.a4_ground_effect.prop_radius_m);
        config.a4_ground_effect.height_clip_m = double_value(a4, "height_clip_m", config.a4_ground_effect.height_clip_m);
        for (std::int32_t index = 0; index < 4; ++index) {
            config.a4_ground_effect.motor_rpm[static_cast<std::size_t>(index)] = double_value(
                    a4, ("motor_" + std::to_string(index) + "_rpm").c_str(),
                    config.a4_ground_effect.motor_rpm[static_cast<std::size_t>(index)]);
        }
    }
    const Variant a5_variant = manifest.get("a5_downwash", Variant());
    if (a5_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary a5 = a5_variant;
        config.a5_downwash.enabled = bool_value(a5, "enabled", config.a5_downwash.enabled);
        config.a5_downwash.prop_radius_m = double_value(a5, "prop_radius_m", config.a5_downwash.prop_radius_m);
        config.a5_downwash.coeff_1 = double_value(a5, "coeff_1", config.a5_downwash.coeff_1);
        config.a5_downwash.coeff_2 = double_value(a5, "coeff_2", config.a5_downwash.coeff_2);
        config.a5_downwash.coeff_3 = double_value(a5, "coeff_3", config.a5_downwash.coeff_3);
    }
    return std::isfinite(config.mass_kg) && config.mass_kg > 0.0 &&
            std::isfinite(config.gravity_mps2) && config.physics_hz > 0 && config.substep_hz > 0;
}

String string_value(const Dictionary &dict, const char *key, const String &fallback) {
    return dict.has(key) ? static_cast<String>(dict[key]) : fallback;
}

Vector3 godot_vec3(const aerosim::Vec3 &value) {
    return {static_cast<real_t>(value.x), static_cast<real_t>(value.y), static_cast<real_t>(value.z)};
}

bool finite_vec3(const aerosim::Vec3 &value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

bool valid_imu_state(const aerosim::RigidBodyState &state) {
    return finite_vec3(state.position) && finite_vec3(state.velocity) && finite_vec3(state.angular_velocity) &&
            finite_vec3(state.propwash_disturbance_rad_s2) && std::isfinite(state.orientation.x) &&
            std::isfinite(state.orientation.y) && std::isfinite(state.orientation.z) &&
            std::isfinite(state.orientation.w) && aerosim::quat_norm(state.orientation) > 0.0;
}

aerosim::WindConfig preset_config(const String &preset) {
    if (preset == "light") {
        return aerosim::wind_preset(aerosim::WindPreset::Light);
    }
    if (preset == "moderate") {
        return aerosim::wind_preset(aerosim::WindPreset::Moderate);
    }
    if (preset == "severe") {
        return aerosim::wind_preset(aerosim::WindPreset::Severe);
    }
    return {};
}

bool valid_wind_preset(const String &preset) {
    return preset == "calm" || preset == "light" || preset == "moderate" || preset == "severe";
}

bool replay_authority_value(std::int32_t value, aerosim::ReplayControllerAuthority &authority) {
    if (value < 0 || value > 2) {
        return false;
    }
    authority = static_cast<aerosim::ReplayControllerAuthority>(value);
    return true;
}

Dictionary replay_status(bool ok, const aerosim::ReplayDiagnostic *diagnostic = nullptr) {
    Dictionary result;
    result["ok"] = ok;
    if (diagnostic != nullptr) {
        result["diagnostic_code"] = static_cast<std::int32_t>(diagnostic->code);
        result["diagnostic_message"] = String(diagnostic->message.c_str());
    }
    return result;
}

void apply_wind(
        aerosim::SimulationConfig &config,
        const aerosim::RigidBodyState &state,
        const aerosim::SimulationClock &clock,
        const aerosim::WindField &wind_field) {
    const double sample_hz = config.substep_hz > 0 ? static_cast<double>(config.substep_hz) : 1.0;
    const double time_seconds = static_cast<double>(clock.total_substeps) / sample_hz;
    config.wind_world_mps = wind_field.sample(time_seconds, state.position);
    config.wind_turbulence_mps = wind_field.turbulence(time_seconds);
}

Dictionary motor_telemetry_dict(const aerosim::MotorTelemetry &motor) {
    Dictionary dict;
    dict["thrust_newtons"] = motor.thrust_newtons;
    dict["speed_rad_s"] = motor.speed_rad_s;
    dict["current_a"] = motor.current_a;
    dict["saturated"] = motor.saturated;
    return dict;
}

Dictionary pid_telemetry_dict(const aerosim::PidAxisTelemetry &axis, bool available) {
    Dictionary dict;
    dict["output"] = available ? Variant(axis.output) : Variant();
    dict["saturated"] = available ? Variant(axis.saturated) : Variant();
    return dict;
}

} // namespace

void AeroSimNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("probe_value"), &AeroSimNative::probe_value);
    ClassDB::bind_method(D_METHOD("trajectory_stride"), &AeroSimNative::trajectory_stride);
    ClassDB::bind_method(D_METHOD("set_hardware_mass_kg", "mass_kg"), &AeroSimNative::set_hardware_mass_kg);
    ClassDB::bind_method(
            D_METHOD("set_hardware_power_model", "max_total_thrust_newtons", "hover_throttle", "motor_tau_s", "battery_nominal_voltage_v", "battery_cells", "battery_cell_resistance_ohm", "max_total_current_a"),
            &AeroSimNative::set_hardware_power_model);
    ClassDB::bind_method(
            D_METHOD("set_hardware_telemetry_model", "max_motor_rpm", "battery_remaining_mah"),
            &AeroSimNative::set_hardware_telemetry_model);
    ClassDB::bind_method(D_METHOD("set_hardware_per_motor_model", "model"), &AeroSimNative::set_hardware_per_motor_model);
    ClassDB::bind_method(
            D_METHOD("set_body_drag_model", "enabled", "coefficient_x", "coefficient_y", "coefficient_z",
                    "frontal_area_x_m2", "frontal_area_y_m2", "frontal_area_z_m2", "center_of_pressure_x_m",
                    "center_of_pressure_y_m", "center_of_pressure_z_m", "air_density_kg_m3"),
            &AeroSimNative::set_body_drag_model);
    ClassDB::bind_method(D_METHOD("set_config_hash", "config_hash"), &AeroSimNative::set_config_hash);
    ClassDB::bind_method(D_METHOD("config_hash"), &AeroSimNative::config_hash);
    ClassDB::bind_method(D_METHOD("body_drag_configuration"), &AeroSimNative::body_drag_configuration);
    ClassDB::bind_method(D_METHOD("reset_simulation"), &AeroSimNative::reset_simulation);
    ClassDB::bind_method(D_METHOD("set_external_force_world", "x", "y", "z"), &AeroSimNative::set_external_force_world);
    ClassDB::bind_method(D_METHOD("set_a5_downwash_source_position", "x", "y", "z"), &AeroSimNative::set_a5_downwash_source_position);
    ClassDB::bind_method(
            D_METHOD("set_dual_aircraft_positions", "upper_x", "upper_y", "upper_z", "lower_x", "lower_y", "lower_z"),
            &AeroSimNative::set_dual_aircraft_positions);
    ClassDB::bind_method(
            D_METHOD("step_dual_aircraft_simulation", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::step_dual_aircraft_simulation);
    ClassDB::bind_method(
            D_METHOD("step_simulation", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::step_simulation);
    ClassDB::bind_method(
            D_METHOD("replay_complete_session", "serialized", "expected_settings_manifest_hash", "expected_upper_config_manifest_hash", "expected_lower_config_manifest_hash", "upper_config_manifest", "lower_config_manifest"),
            &AeroSimNative::replay_complete_session);
    ClassDB::bind_method(
            D_METHOD("compare_complete_replay_sessions", "expected_serialized", "actual_serialized", "expected_settings_manifest_hash"),
            &AeroSimNative::compare_complete_replay_sessions);
    ClassDB::bind_method(
            D_METHOD("replay_vehicle_config_manifest"),
            &AeroSimNative::replay_vehicle_config_manifest);
    ClassDB::bind_method(
            D_METHOD("replay_manifest_hash", "config_json"),
            &AeroSimNative::replay_manifest_hash);
    ClassDB::bind_method(
            D_METHOD("begin_complete_replay_recording", "seed", "settings_manifest_hash", "upper_name", "upper_config_manifest_hash", "upper_config_json", "upper_controller_authority", "lower_name", "lower_config_manifest_hash", "lower_config_json", "lower_controller_authority"),
            &AeroSimNative::begin_complete_replay_recording);
    ClassDB::bind_method(D_METHOD("begin_replay_checkpoint_capture"), &AeroSimNative::begin_replay_checkpoint_capture);
    ClassDB::bind_method(D_METHOD("capture_replay_recorded_response", "non_neutral"), &AeroSimNative::capture_replay_recorded_response);
    ClassDB::bind_method(
            D_METHOD("record_replay_command", "timestamp_us", "vehicle_name", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second", "controller_authority"),
            &AeroSimNative::record_replay_command);
    ClassDB::bind_method(
            D_METHOD("record_replay_mode_command", "timestamp_us", "vehicle_name", "mode", "throttle", "roll", "pitch", "yaw", "rc_rate", "super_rate", "expo", "measured_altitude_m", "controller_authority"),
            &AeroSimNative::record_replay_mode_command);
    ClassDB::bind_method(
            D_METHOD("record_replay_actuator_command", "timestamp_us", "vehicle_name", "motor_0", "motor_1", "motor_2", "motor_3", "controller_authority"),
            &AeroSimNative::record_replay_actuator_command);
    ClassDB::bind_method(
            D_METHOD("record_replay_simulation_operation", "timestamp_us", "operation", "value"),
            &AeroSimNative::record_replay_simulation_operation);
    ClassDB::bind_method(
            D_METHOD("record_replay_collision", "timestamp_us", "vehicle_name", "touching", "normal_x", "normal_y", "normal_z", "impulse_x", "impulse_y", "impulse_z", "restitution", "resolved_velocity_x", "resolved_velocity_y", "resolved_velocity_z", "resolved_angular_velocity_x", "resolved_angular_velocity_y", "resolved_angular_velocity_z", "max_kinetic_energy_joules", "has_resolved_state", "controller_authority"),
            &AeroSimNative::record_replay_collision);
    ClassDB::bind_method(
            D_METHOD("record_replay_scene_object", "timestamp_us", "operation", "object_name", "asset_id", "position", "orientation"),
            &AeroSimNative::record_replay_scene_object);
    ClassDB::bind_method(
            D_METHOD("record_replay_environment", "timestamp_us", "environment_json"),
            &AeroSimNative::record_replay_environment);
    ClassDB::bind_method(
            D_METHOD("record_replay_checkpoint", "timestamp_us", "upper_row", "lower_row", "lower_native"),
            &AeroSimNative::record_replay_checkpoint);
    ClassDB::bind_method(
            D_METHOD("record_replay_async_command", "timestamp_us", "vehicle_name", "command_id", "method", "lifecycle"),
            &AeroSimNative::record_replay_async_command);
    ClassDB::bind_method(
            D_METHOD("finish_complete_replay_recording", "timestamp_us", "reason"),
            &AeroSimNative::finish_complete_replay_recording);
    ClassDB::bind_method(
            D_METHOD("step_px4_actuator_mode", "physics_hz", "substep_hz", "motor_0", "motor_1", "motor_2", "motor_3"),
            &AeroSimNative::step_px4_actuator_mode);
    ClassDB::bind_method(
            D_METHOD("step_collision_px4_actuator_mode", "physics_hz", "substep_hz", "motor_0", "motor_1", "motor_2", "motor_3", "touching", "normal_x", "normal_y", "normal_z", "impulse_x", "impulse_y", "impulse_z", "restitution", "resolved_velocity_x", "resolved_velocity_y", "resolved_velocity_z", "resolved_angular_velocity_x", "resolved_angular_velocity_y", "resolved_angular_velocity_z", "max_kinetic_energy_joules"),
            &AeroSimNative::step_collision_px4_actuator_mode);
    ClassDB::bind_method(D_METHOD("arm_flight_control", "throttle"), &AeroSimNative::arm_flight_control);
    ClassDB::bind_method(D_METHOD("disarm_flight_control"), &AeroSimNative::disarm_flight_control);
    ClassDB::bind_method(D_METHOD("flight_control_armed"), &AeroSimNative::flight_control_armed);
    ClassDB::bind_method(D_METHOD("flight_control_arm_reject_code"), &AeroSimNative::flight_control_arm_reject_code);
    ClassDB::bind_method(
            D_METHOD("betaflight_stick_for_rate", "rate_degrees_per_second", "rc_rate", "super_rate", "expo"),
            &AeroSimNative::betaflight_stick_for_rate);
    ClassDB::bind_method(
            D_METHOD("betaflight_rate_for_stick", "stick", "rc_rate", "super_rate", "expo"),
            &AeroSimNative::betaflight_rate_for_stick);
    ClassDB::bind_method(D_METHOD("reset_flight"), &AeroSimNative::reset_flight);
    ClassDB::bind_method(D_METHOD("capture_altitude_hold"), &AeroSimNative::capture_altitude_hold);
    ClassDB::bind_method(D_METHOD("configure_imu", "config"), &AeroSimNative::configure_imu);
    ClassDB::bind_method(D_METHOD("imu_configuration"), &AeroSimNative::imu_configuration);
    ClassDB::bind_method(D_METHOD("imu_sample"), &AeroSimNative::imu_sample);
    ClassDB::bind_method(D_METHOD("refresh_imu_sample"), &AeroSimNative::refresh_imu_sample);
    ClassDB::bind_method(D_METHOD("last_step_error"), &AeroSimNative::last_step_error);
    ClassDB::bind_method(D_METHOD("configure_wind", "config"), &AeroSimNative::configure_wind);
    ClassDB::bind_method(D_METHOD("wind_configuration"), &AeroSimNative::wind_configuration);
    ClassDB::bind_method(D_METHOD("sample_wind", "time_seconds", "position_x", "position_y", "position_z"), &AeroSimNative::sample_wind);
    ClassDB::bind_method(D_METHOD("flight_control_diagnostics"), &AeroSimNative::flight_control_diagnostics);
    ClassDB::bind_method(D_METHOD("hardware_power_diagnostics"), &AeroSimNative::hardware_power_diagnostics);
    ClassDB::bind_method(D_METHOD("hardware_per_motor_diagnostics"), &AeroSimNative::hardware_per_motor_diagnostics);
    ClassDB::bind_method(D_METHOD("telemetry_snapshot"), &AeroSimNative::telemetry_snapshot);
    ClassDB::bind_method(
            D_METHOD("set_a3_drag_model", "enabled", "coefficient_x_kg", "coefficient_y_kg", "coefficient_z_kg"),
            &AeroSimNative::set_a3_drag_model);
    ClassDB::bind_method(D_METHOD("a3_drag_configuration"), &AeroSimNative::a3_drag_configuration);
    ClassDB::bind_method(
            D_METHOD("set_a6_propwash_model", "enabled", "full_collective_angular_accel_rad_s2", "minimum_wake_entry_speed_mps", "minimum_transverse_rate_rad_s"),
            &AeroSimNative::set_a6_propwash_model);
    ClassDB::bind_method(D_METHOD("a6_propwash_configuration"), &AeroSimNative::a6_propwash_configuration);
    ClassDB::bind_method(
            D_METHOD("set_a4_ground_effect_model", "enabled", "kf", "ground_effect_coeff", "prop_radius_m", "height_clip_m", "motor_0_rpm", "motor_1_rpm", "motor_2_rpm", "motor_3_rpm"),
            &AeroSimNative::set_a4_ground_effect_model);
    ClassDB::bind_method(D_METHOD("a4_ground_effect_configuration"), &AeroSimNative::a4_ground_effect_configuration);
    ClassDB::bind_method(
            D_METHOD("set_a5_downwash_model", "enabled", "prop_radius_m", "coeff_1", "coeff_2", "coeff_3"),
            &AeroSimNative::set_a5_downwash_model);
    ClassDB::bind_method(D_METHOD("a5_downwash_configuration"), &AeroSimNative::a5_downwash_configuration);
    ClassDB::bind_method(
            D_METHOD("a5_downwash_force_y", "upper_x", "upper_y", "upper_z", "lower_x", "lower_y", "lower_z"),
            &AeroSimNative::a5_downwash_force_y);
    ClassDB::bind_method(D_METHOD("set_collision_release_frames", "release_frames"), &AeroSimNative::set_collision_release_frames);
    ClassDB::bind_method(
            D_METHOD("sync_flight_state", "position_x", "position_y", "position_z", "orientation_x", "orientation_y", "orientation_z", "orientation_w", "velocity_x", "velocity_y", "velocity_z", "angular_velocity_x", "angular_velocity_y", "angular_velocity_z"),
            &AeroSimNative::sync_flight_state);
    ClassDB::bind_method(
            D_METHOD("step_angle_mode", "physics_hz", "substep_hz", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second"),
            &AeroSimNative::step_angle_mode);
    ClassDB::bind_method(
            D_METHOD("step_acro_mode", "physics_hz", "substep_hz", "throttle", "roll_stick", "pitch_stick", "yaw_stick", "rc_rate", "super_rate", "expo"),
            &AeroSimNative::step_acro_mode);
    ClassDB::bind_method(
            D_METHOD("step_altitude_hold_mode", "physics_hz", "substep_hz", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second"),
            &AeroSimNative::step_altitude_hold_mode);
    ClassDB::bind_method(
            D_METHOD("step_collision_angle_mode", "physics_hz", "substep_hz", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second", "touching", "normal_x", "normal_y", "normal_z", "impulse_x", "impulse_y", "impulse_z", "restitution", "resolved_velocity_x", "resolved_velocity_y", "resolved_velocity_z", "resolved_angular_velocity_x", "resolved_angular_velocity_y", "resolved_angular_velocity_z", "max_kinetic_energy_joules"),
            &AeroSimNative::step_collision_angle_mode);
    ClassDB::bind_method(
            D_METHOD("step_collision_altitude_hold_mode", "physics_hz", "substep_hz", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second", "touching", "normal_x", "normal_y", "normal_z", "impulse_x", "impulse_y", "impulse_z", "restitution", "resolved_velocity_x", "resolved_velocity_y", "resolved_velocity_z", "resolved_angular_velocity_x", "resolved_angular_velocity_y", "resolved_angular_velocity_z", "max_kinetic_energy_joules"),
            &AeroSimNative::step_collision_altitude_hold_mode);
    ClassDB::bind_method(
            D_METHOD("step_collision_acro_mode", "physics_hz", "substep_hz", "throttle", "roll_stick", "pitch_stick", "yaw_stick", "rc_rate", "super_rate", "expo", "touching", "normal_x", "normal_y", "normal_z", "impulse_x", "impulse_y", "impulse_z", "restitution", "resolved_velocity_x", "resolved_velocity_y", "resolved_velocity_z", "resolved_angular_velocity_x", "resolved_angular_velocity_y", "resolved_angular_velocity_z", "max_kinetic_energy_joules"),
            &AeroSimNative::step_collision_acro_mode);
    ClassDB::bind_method(
            D_METHOD("simulate_trajectory", "seconds", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::simulate_trajectory);
}

std::int32_t AeroSimNative::probe_value() const {
    return aerosim::probe_value();
}

std::int32_t AeroSimNative::trajectory_stride() const {
    return 12;
}

bool AeroSimNative::set_hardware_mass_kg(double mass_kg) {
    return hardware_config_.set_mass_kg(mass_kg);
}

bool AeroSimNative::set_hardware_power_model(
        double max_total_thrust_newtons,
        double hover_throttle,
        double motor_tau_s,
        double battery_nominal_voltage_v,
        double battery_cells,
        double battery_cell_resistance_ohm,
        double max_total_current_a) {
    return hardware_config_.set_power_model(
            max_total_thrust_newtons,
            hover_throttle,
            motor_tau_s,
            battery_nominal_voltage_v,
            battery_cells,
            battery_cell_resistance_ohm,
            max_total_current_a);
}

bool AeroSimNative::set_hardware_telemetry_model(double max_motor_rpm, double battery_remaining_mah) {
    return hardware_config_.set_telemetry_model(max_motor_rpm, battery_remaining_mah);
}

bool AeroSimNative::set_hardware_per_motor_model(const Dictionary &model) {
    aerosim::PerMotorPhysicsConfig per_motor;
    return per_motor_model_value(model, per_motor) && hardware_config_.set_per_motor_model(per_motor);
}

void AeroSimNative::reset_simulation() {
    simulation_state_ = {};
    simulation_clock_ = {};
    dual_aircraft_state_ = {};
    dual_aircraft_clock_ = {};
    external_force_world_ = {};
    downwash_source_position_world_ = {};
    downwash_source_enabled_ = false;
    collision_authority_ = {};
    last_imu_sample_ = {};
    has_last_imu_sample_ = false;
    clear_step_error();
}

void AeroSimNative::set_external_force_world(double x, double y, double z) {
    if (std::isfinite(x) && std::isfinite(y) && std::isfinite(z)) {
        external_force_world_ = {x, y, z};
    }
}

void AeroSimNative::set_a5_downwash_source_position(double x, double y, double z) {
    if (std::isfinite(x) && std::isfinite(y) && std::isfinite(z)) {
        downwash_source_position_world_ = {x, y, z};
        downwash_source_enabled_ = true;
    } else {
        downwash_source_enabled_ = false;
    }
}

void AeroSimNative::apply_downwash_provider(aerosim::SimulationConfig &config) const {
    config.a5_downwash = a5_downwash_config_;
    if (!downwash_source_enabled_) {
        config.external_force_provider = {};
        return;
    }
    const aerosim::Vec3 source_position = downwash_source_position_world_;
    const aerosim::A5DownwashConfig downwash_config = config.a5_downwash;
    config.external_force_provider = [source_position, downwash_config](const aerosim::Vec3 &target_position) {
        return aerosim::Vec3{0.0, aerosim::a5_downwash_force_y_newtons(downwash_config, source_position, target_position), 0.0};
    };
}

AeroSimNative::StepSnapshot AeroSimNative::snapshot_step() const {
    return {
            simulation_state_, simulation_clock_, flight_controller_, collision_authority_, imu_, last_imu_sample_,
            has_last_imu_sample_, flight_control_used_estimated_attitude_, flight_mode_,
    };
}

void AeroSimNative::restore_step(const StepSnapshot &snapshot) {
    simulation_state_ = snapshot.simulation_state;
    simulation_clock_ = snapshot.simulation_clock;
    flight_controller_ = snapshot.flight_controller;
    collision_authority_ = snapshot.collision_authority;
    imu_ = snapshot.imu;
    last_imu_sample_ = snapshot.last_imu_sample;
    has_last_imu_sample_ = snapshot.has_last_imu_sample;
    flight_control_used_estimated_attitude_ = snapshot.flight_control_used_estimated_attitude;
    flight_mode_ = snapshot.flight_mode;
}

void AeroSimNative::set_step_error(const char *method, aerosim::StepStatus status, const char *reason) {
    last_step_error_ = String("AeroSimNative.") + method + ": " + aerosim::step_status_code(status) + ": " + reason;
    ERR_PRINT(last_step_error_);
}

void AeroSimNative::clear_step_error() {
    last_step_error_ = "";
}

bool AeroSimNative::set_dual_aircraft_positions(
        double upper_x,
        double upper_y,
        double upper_z,
        double lower_x,
        double lower_y,
        double lower_z) {
    const double values[] = {upper_x, upper_y, upper_z, lower_x, lower_y, lower_z};
    for (double value : values) {
        if (!std::isfinite(value)) {
            return false;
        }
    }
    dual_aircraft_state_ = {};
    dual_aircraft_state_.upper.position = {upper_x, upper_y, upper_z};
    dual_aircraft_state_.lower.position = {lower_x, lower_y, lower_z};
    dual_aircraft_clock_ = {};
    return true;
}

PackedFloat64Array AeroSimNative::step_dual_aircraft_simulation(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double total_thrust_newtons) {
    if (physics_hz <= 0 || substep_hz <= 0 ||
            !std::isfinite(total_thrust_newtons) || total_thrust_newtons < 0.0) {
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.total_thrust_newtons = flight_controller_.armed() ? total_thrust_newtons : 0.0;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    config.a5_downwash = a5_downwash_config_;
    aerosim::DualAircraftConfig dual_config{config, config};
    apply_wind(dual_config.upper, dual_aircraft_state_.upper, dual_aircraft_clock_, wind_field_);
    apply_wind(dual_config.lower, dual_aircraft_state_.lower, dual_aircraft_clock_, wind_field_);
    if (dual_config.upper.per_motor.max_thrust_per_motor_newtons <= 0.0) {
        return {};
    }
    const double command_value = config.total_thrust_newtons /
            (4.0 * dual_config.upper.per_motor.max_thrust_per_motor_newtons);
    if (!std::isfinite(command_value) || command_value < 0.0 || command_value > 1.0) {
        return {};
    }
    const aerosim::DualMotorCommands commands{
            {{command_value, command_value, command_value, command_value}},
            {{command_value, command_value, command_value, command_value}},
    };
    const aerosim::DualAircraftTrajectorySample sample = aerosim::step_dual_aircraft_per_motor_physics_frame(
            dual_aircraft_state_, dual_aircraft_clock_, dual_config, commands);
    if (sample.substeps == 0 && physics_hz > 0 && substep_hz > 0) {
        return {};
    }
    PackedFloat64Array row;
    row.append(sample.time_seconds);
    row.append(sample.state.upper.position.x);
    row.append(sample.state.upper.position.y);
    row.append(sample.state.upper.position.z);
    row.append(sample.state.lower.position.x);
    row.append(sample.state.lower.position.y);
    row.append(sample.state.lower.position.z);
    row.append(sample.state.lower.velocity.y);
    row.append(sample.downwash_force_y_newtons);
    row.append(sample.minimum_downwash_force_y_newtons);
    row.append(static_cast<double>(sample.substeps));
    return row;
}

PackedFloat64Array AeroSimNative::step_simulation(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double total_thrust_newtons) {
    if (physics_hz <= 0 || substep_hz <= 0) {
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.total_thrust_newtons = flight_controller_.armed() ? total_thrust_newtons : 0.0;
    if (flight_controller_.armed()) {
        simulation_state_.motor_thrust_newtons.fill(total_thrust_newtons / 4.0);
    } else {
        simulation_state_.motor_thrust_newtons = {};
    }
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    PackedFloat64Array row;
    const aerosim::TrajectorySample sample = aerosim::step_physics_frame(simulation_state_, simulation_clock_, config);
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    return row;
}

Dictionary AeroSimNative::replay_complete_session(
        const String &serialized,
        const String &expected_settings_manifest_hash,
        const String &expected_upper_config_manifest_hash,
        const String &expected_lower_config_manifest_hash,
        const Dictionary &upper_config_manifest,
        const Dictionary &lower_config_manifest) {
    Dictionary result;
    if (expected_settings_manifest_hash.is_empty() || expected_upper_config_manifest_hash.is_empty() ||
            expected_lower_config_manifest_hash.is_empty()) {
        result["ok"] = false;
        result["diagnostic_code"] = static_cast<std::int32_t>(aerosim::ReplayDiagnosticCode::MissingManifest);
        result["diagnostic_message"] = "expected settings and vehicle config manifest hashes are required";
        return result;
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(
            std::string(serialized.utf8().get_data()),
            std::string(expected_settings_manifest_hash.utf8().get_data()));
    result["ok"] = loaded.ok;
    result["diagnostic_code"] = static_cast<std::int32_t>(loaded.diagnostic.code);
    result["diagnostic_message"] = String(loaded.diagnostic.message.c_str());
    if (!loaded.ok) {
        return result;
    }
    for (const auto &vehicle : loaded.session.vehicles) {
        if (std::string(sha256_string(String(vehicle.config_json.c_str())).utf8().get_data()) != vehicle.config_manifest_hash) {
            const aerosim::ReplayDiagnostic diagnostic{
                    aerosim::ReplayDiagnosticCode::IncompatibleManifest,
                    "vehicle config manifest hash does not match its config JSON"};
            return replay_status(false, &diagnostic);
        }
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = 240;
    config.substep_hz = 1000;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.a5_downwash = a5_downwash_config_;
    config.external_force_world = external_force_world_;
    aerosim::SimulationConfig upper_config = config;
    aerosim::SimulationConfig lower_config = config;
    if (!simulation_config_manifest_value(upper_config_manifest, upper_config) ||
            !simulation_config_manifest_value(lower_config_manifest, lower_config)) {
        const aerosim::ReplayDiagnostic diagnostic{
                aerosim::ReplayDiagnosticCode::MissingVehicleConfig,
                "replay vehicle config manifests are malformed"};
        return replay_status(false, &diagnostic);
    }
    const aerosim::ReplayRunResult run = aerosim::replay_session(
            loaded.session,
            aerosim::DualAircraftConfig{upper_config, lower_config},
            std::string(expected_settings_manifest_hash.utf8().get_data()),
            {std::string(expected_upper_config_manifest_hash.utf8().get_data()),
             std::string(expected_lower_config_manifest_hash.utf8().get_data())},
            true);
    result["ok"] = run.ok;
    result["diagnostic_code"] = static_cast<std::int32_t>(run.diagnostic.code);
    result["diagnostic_message"] = String(run.diagnostic.message.c_str());
    if (run.ok) {
        if (!loaded.session.checkpoints.empty()) {
            aerosim::ReplayRunResult expected_run = run;
            expected_run.checkpoints = loaded.session.checkpoints;
            const aerosim::ReplayDivergence divergence = aerosim::compare_replay_runs(expected_run, run);
            result["diverged"] = divergence.diverged;
            result["divergence_timestamp_us"] = static_cast<std::int64_t>(divergence.timestamp_us);
            result["divergence_vehicle_name"] = String(divergence.vehicle_name.c_str());
            result["divergence_field"] = String(divergence.field.c_str());
            result["divergence_expected"] = String(divergence.expected.c_str());
            result["divergence_actual"] = String(divergence.actual.c_str());
            result["divergence_tolerance"] = divergence.tolerance;
            if (divergence.diverged) {
                result["ok"] = false;
                result["diagnostic_code"] = static_cast<std::int32_t>(aerosim::ReplayDiagnosticCode::InvalidSession);
                result["diagnostic_message"] = String(("replay checkpoint diverged: " + divergence.field).c_str());
                return result;
            }
        }
        result["upper_position"] = godot_vec3(run.final_state.upper.position);
        result["lower_position"] = godot_vec3(run.final_state.lower.position);
        result["total_substeps"] = static_cast<std::int64_t>(run.final_clock.total_substeps);
        result["scene_object_count"] = static_cast<std::int64_t>(run.scene_objects.size());
        result["environment_json"] = String(run.environment_json.c_str());
    }
    return result;
}

Dictionary AeroSimNative::compare_complete_replay_sessions(
        const String &expected_serialized,
        const String &actual_serialized,
        const String &expected_settings_manifest_hash) {
    Dictionary result;
    const aerosim::ReplayLoadResult expected = aerosim::load_replay_session(
            std::string(expected_serialized.utf8().get_data()),
            std::string(expected_settings_manifest_hash.utf8().get_data()));
    if (!expected.ok) {
        return replay_status(false, &expected.diagnostic);
    }
    const aerosim::ReplayLoadResult actual = aerosim::load_replay_session(
            std::string(actual_serialized.utf8().get_data()),
            std::string(expected_settings_manifest_hash.utf8().get_data()));
    if (!actual.ok) {
        return replay_status(false, &actual.diagnostic);
    }
    const aerosim::ReplayDivergence divergence = aerosim::compare_replay_sessions(expected.session, actual.session);
    result["ok"] = true;
    result["diverged"] = divergence.diverged;
    result["timestamp_us"] = static_cast<std::int64_t>(divergence.timestamp_us);
    result["vehicle_name"] = String(divergence.vehicle_name.c_str());
    result["field"] = String(divergence.field.c_str());
    result["expected"] = String(divergence.expected.c_str());
    result["actual"] = String(divergence.actual.c_str());
    result["tolerance"] = divergence.tolerance;
    return result;
}

Dictionary AeroSimNative::replay_vehicle_config_manifest() const {
    const aerosim::SimulationConfig config = hardware_config_.simulation_config();
    Dictionary result;
    result["mass_kg"] = config.mass_kg;
    result["gravity_mps2"] = config.gravity_mps2;
    result["physics_hz"] = config.physics_hz;
    result["substep_hz"] = config.substep_hz;
    result["max_total_thrust_newtons"] = config.max_total_thrust_newtons;
    result["hover_throttle"] = config.hover_throttle;
    result["motor_tau_s"] = config.motor_tau_s;
    result["battery_nominal_voltage_v"] = config.battery_nominal_voltage_v;
    result["battery_cells"] = config.battery_cells;
    result["battery_cell_resistance_ohm"] = config.battery_cell_resistance_ohm;
    result["battery_remaining_mah"] = config.battery_remaining_mah;
    result["max_total_current_a"] = config.max_total_current_a;
    result["max_motor_rpm"] = config.max_motor_rpm;
    result["external_force_world"] = godot_vec3(external_force_world_);
    result["a3_drag"] = a3_drag_configuration();
    result["a6_propwash"] = a6_propwash_configuration();
    result["body_drag"] = body_drag_configuration();
    result["a4_ground_effect"] = a4_ground_effect_configuration();
    result["a5_downwash"] = a5_downwash_configuration();
    Dictionary per_motor;
    per_motor["inertia_frd"] = godot_vec3(config.per_motor.inertia_kg_m2);
    Array positions;
    Array spins;
    for (std::size_t index = 0; index < 4; ++index) {
        positions.push_back(godot_vec3(config.per_motor.position_frd[index]));
        spins.push_back(config.per_motor.spin_direction[index]);
    }
    per_motor["position_frd"] = positions;
    per_motor["spin_direction"] = spins;
    per_motor["max_thrust_per_motor_newtons"] = config.per_motor.max_thrust_per_motor_newtons;
    per_motor["max_current_per_motor_a"] = config.per_motor.max_current_per_motor_a;
    per_motor["yaw_torque_per_newton"] = config.per_motor.yaw_torque_per_newton;
    result["per_motor"] = per_motor;
    return result;
}

String AeroSimNative::replay_manifest_hash(const String &config_json) const {
    return sha256_string(config_json);
}

void AeroSimNative::begin_replay_checkpoint_capture() {
    replay_first_response_ = {};
    has_replay_first_response_ = false;
    replay_last_successful_step_ = {};
    has_replay_last_successful_step_ = false;
    replay_checkpoint_capture_active_ = true;
}

void AeroSimNative::capture_replay_first_response(const aerosim::TrajectorySample &sample) {
    if (replay_checkpoint_capture_active_) {
        replay_last_successful_step_ = sample;
        if (sample.first_substeps > 0) {
            replay_last_successful_step_.time_seconds = sample.first_substep_time_seconds;
            replay_last_successful_step_.state = sample.first_substep_state;
            replay_last_successful_step_.substeps = sample.first_substeps;
        }
        has_replay_last_successful_step_ = replay_last_successful_step_.substeps > 0;
    }
}

void AeroSimNative::capture_replay_recorded_response(bool non_neutral) {
    if (replay_checkpoint_capture_active_ && non_neutral && !has_replay_first_response_ &&
            has_replay_last_successful_step_) {
        replay_first_response_ = replay_last_successful_step_;
        has_replay_first_response_ = true;
    }
}

Dictionary AeroSimNative::begin_complete_replay_recording(
        std::int64_t seed,
        const String &settings_manifest_hash,
        const String &upper_name,
        const String &upper_config_manifest_hash,
        const String &upper_config_json,
        std::int32_t upper_controller_authority,
        const String &lower_name,
        const String &lower_config_manifest_hash,
        const String &lower_config_json,
        std::int32_t lower_controller_authority) {
    if (seed < 0 || settings_manifest_hash.is_empty() || upper_name.is_empty() || upper_config_manifest_hash.is_empty() ||
            upper_config_json.is_empty() || lower_name.is_empty() || lower_config_manifest_hash.is_empty() ||
            lower_config_json.is_empty()) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::MissingManifest, "replay recording requires settings and vehicle manifests"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayControllerAuthority upper_authority;
    aerosim::ReplayControllerAuthority lower_authority;
    if (!replay_authority_value(upper_controller_authority, upper_authority) ||
            !replay_authority_value(lower_controller_authority, lower_authority)) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording controller authority is invalid"};
        return replay_status(false, &diagnostic);
    }
    auto recorder = std::make_unique<aerosim::ReplaySessionRecorder>(
            static_cast<std::uint64_t>(seed), std::string(settings_manifest_hash.utf8().get_data()));
    if (!recorder->add_vehicle(std::string(upper_name.utf8().get_data()),
                std::string(upper_config_manifest_hash.utf8().get_data()),
                std::string(upper_config_json.utf8().get_data()), upper_authority) ||
            !recorder->add_vehicle(std::string(lower_name.utf8().get_data()),
                std::string(lower_config_manifest_hash.utf8().get_data()),
                std::string(lower_config_json.utf8().get_data()), lower_authority)) {
        return replay_status(false, &recorder->diagnostic());
    }
    replay_recorder_ = std::move(recorder);
    begin_replay_checkpoint_capture();
    return replay_status(true);
}

Dictionary AeroSimNative::record_replay_command(
        std::int64_t timestamp_us,
        const String &vehicle_name,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second,
        std::int32_t controller_authority) {
    if (replay_recorder_ == nullptr || timestamp_us < 0) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording is not active"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayControllerAuthority authority;
    if (!replay_authority_value(controller_authority, authority)) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay command authority is invalid"};
        return replay_status(false, &diagnostic);
    }
    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;
    const bool ok = replay_recorder_->record_command(static_cast<std::uint64_t>(timestamp_us),
            std::string(vehicle_name.utf8().get_data()), command, authority);
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_mode_command(
        std::int64_t timestamp_us,
        const String &vehicle_name,
        const String &mode,
        double throttle,
        double roll,
        double pitch,
        double yaw,
        double rc_rate,
        double super_rate,
        double expo,
        double measured_altitude_m,
        std::int32_t controller_authority) {
    if (replay_recorder_ == nullptr || timestamp_us < 0) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording is not active"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayControllerAuthority authority;
    if (!replay_authority_value(controller_authority, authority)) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay command authority is invalid"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayCommandMode command_mode;
    const std::string mode_name = std::string(mode.utf8().get_data());
    if (mode_name == "ACRO") {
        command_mode = aerosim::ReplayCommandMode::Acro;
    } else if (mode_name == "ALTITUDE_HOLD") {
        command_mode = aerosim::ReplayCommandMode::AltitudeHold;
    } else if (mode_name == "ANGLE") {
        command_mode = aerosim::ReplayCommandMode::Angle;
    } else {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay command mode is invalid"};
        return replay_status(false, &diagnostic);
    }
    aerosim::FlightCommand angle_command;
    angle_command.throttle = throttle;
    angle_command.roll_degrees = roll;
    angle_command.pitch_degrees = pitch;
    angle_command.yaw_rate_degrees_per_second = yaw;
    aerosim::AcroCommand acro_command;
    acro_command.throttle = throttle;
    acro_command.roll_stick = roll;
    acro_command.pitch_stick = pitch;
    acro_command.yaw_stick = yaw;
    acro_command.rates = {rc_rate, super_rate, expo};
    const bool ok = replay_recorder_->record_mode_command(static_cast<std::uint64_t>(timestamp_us),
            std::string(vehicle_name.utf8().get_data()), command_mode, angle_command, acro_command, authority,
            measured_altitude_m);
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_actuator_command(
        std::int64_t timestamp_us,
        const String &vehicle_name,
        double motor_0,
        double motor_1,
        double motor_2,
        double motor_3,
        std::int32_t controller_authority) {
    if (replay_recorder_ == nullptr || timestamp_us < 0) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording is not active"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayControllerAuthority authority;
    if (!replay_authority_value(controller_authority, authority)) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay actuator authority is invalid"};
        return replay_status(false, &diagnostic);
    }
    aerosim::MotorCommands commands{{motor_0, motor_1, motor_2, motor_3}};
    const bool ok = replay_recorder_->record_actuator_command(static_cast<std::uint64_t>(timestamp_us),
            std::string(vehicle_name.utf8().get_data()), commands, authority);
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_simulation_operation(
        std::int64_t timestamp_us, std::int32_t operation, double value) {
    if (replay_recorder_ == nullptr || timestamp_us < 0 || operation < 0 || operation > 5) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay simulation operation is invalid or recording is inactive"};
        return replay_status(false, &diagnostic);
    }
    const bool ok = replay_recorder_->record_simulation_operation(
            static_cast<std::uint64_t>(timestamp_us), static_cast<aerosim::ReplaySimulationOperation>(operation), value);
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_collision(
        std::int64_t timestamp_us,
        const String &vehicle_name,
        bool touching,
        double normal_x,
        double normal_y,
        double normal_z,
        double impulse_x,
        double impulse_y,
        double impulse_z,
        double restitution,
        double resolved_velocity_x,
        double resolved_velocity_y,
        double resolved_velocity_z,
        double resolved_angular_velocity_x,
        double resolved_angular_velocity_y,
        double resolved_angular_velocity_z,
        double max_kinetic_energy_joules,
        bool has_resolved_state,
        std::int32_t controller_authority) {
    if (replay_recorder_ == nullptr || timestamp_us < 0) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording is not active"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayControllerAuthority authority;
    if (!replay_authority_value(controller_authority, authority)) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay collision authority is invalid"};
        return replay_status(false, &diagnostic);
    }
    aerosim::CollisionContact contact;
    contact.touching = touching;
    contact.normal = {normal_x, normal_y, normal_z};
    contact.impulse = {impulse_x, impulse_y, impulse_z};
    contact.restitution = restitution;
    contact.resolved_velocity = {resolved_velocity_x, resolved_velocity_y, resolved_velocity_z};
    contact.resolved_angular_velocity = {resolved_angular_velocity_x, resolved_angular_velocity_y, resolved_angular_velocity_z};
    contact.max_kinetic_energy_joules = max_kinetic_energy_joules;
    contact.has_resolved_state = has_resolved_state;
    const bool ok = replay_recorder_->record_collision(static_cast<std::uint64_t>(timestamp_us),
            std::string(vehicle_name.utf8().get_data()), contact, authority);
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_scene_object(
        std::int64_t timestamp_us,
        std::int32_t operation,
        const String &object_name,
        const String &asset_id,
        const Vector3 &position,
        const Quaternion &orientation) {
    if (replay_recorder_ == nullptr || timestamp_us < 0 || operation < 0 || operation > 3) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay scene operation is invalid or recording is inactive"};
        return replay_status(false, &diagnostic);
    }
    const bool ok = replay_recorder_->record_scene_object(static_cast<std::uint64_t>(timestamp_us),
            static_cast<aerosim::ReplaySceneObjectOperation>(operation), std::string(object_name.utf8().get_data()),
            std::string(asset_id.utf8().get_data()), {position.x, position.y, position.z},
            {orientation.x, orientation.y, orientation.z, orientation.w});
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_environment(
        std::int64_t timestamp_us, const String &environment_json) {
    if (replay_recorder_ == nullptr || timestamp_us < 0) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording is not active"};
        return replay_status(false, &diagnostic);
    }
    const bool ok = replay_recorder_->record_environment(static_cast<std::uint64_t>(timestamp_us),
            std::string(environment_json.utf8().get_data()));
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_checkpoint(
        std::int64_t timestamp_us,
        const PackedFloat64Array &upper_row,
        const PackedFloat64Array &lower_row,
        AeroSimNative *lower_native) {
    if (replay_recorder_ == nullptr || lower_native == nullptr || timestamp_us < 0 || upper_row.size() < 12 || lower_row.size() < 12) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay checkpoint state is invalid or recording is inactive"};
        return replay_status(false, &diagnostic);
    }
    aerosim::ReplayRunCheckpoint checkpoint;
    checkpoint.state = {simulation_state_, lower_native->simulation_state_};
    checkpoint.controllers[0] = flight_controller_.control_state();
    checkpoint.controllers[1] = lower_native->flight_controller_.control_state();
    checkpoint.clocks[0] = simulation_clock_;
    checkpoint.clocks[1] = lower_native->simulation_clock_;
    checkpoint.first_response_substeps[0] = replay_first_response_;
    checkpoint.first_response_substeps[1] = lower_native->replay_first_response_;
    const bool ok = replay_recorder_->record_checkpoint(static_cast<std::uint64_t>(timestamp_us), std::move(checkpoint));
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::record_replay_async_command(
        std::int64_t timestamp_us,
        const String &vehicle_name,
        const String &command_id,
        const String &method,
        std::int32_t lifecycle) {
    if (replay_recorder_ == nullptr || timestamp_us < 0 || lifecycle < 0 || lifecycle > 4) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay async lifecycle is invalid or recording is inactive"};
        return replay_status(false, &diagnostic);
    }
    const bool ok = replay_recorder_->record_async_command(static_cast<std::uint64_t>(timestamp_us),
            std::string(vehicle_name.utf8().get_data()), std::string(command_id.utf8().get_data()),
            std::string(method.utf8().get_data()), static_cast<aerosim::ReplayAsyncLifecycle>(lifecycle));
    return replay_status(ok, &replay_recorder_->diagnostic());
}

Dictionary AeroSimNative::finish_complete_replay_recording(
        std::int64_t timestamp_us, const String &reason) {
    if (replay_recorder_ == nullptr || timestamp_us < 0) {
        const aerosim::ReplayDiagnostic diagnostic{aerosim::ReplayDiagnosticCode::InvalidSession, "replay recording is not active"};
        return replay_status(false, &diagnostic);
    }
    if (!replay_recorder_->finish(static_cast<std::uint64_t>(timestamp_us), std::string(reason.utf8().get_data()))) {
        return replay_status(false, &replay_recorder_->diagnostic());
    }
    Dictionary result = replay_status(true);
    result["serialized"] = String(replay_recorder_->serialize().c_str());
    return result;
}

PackedFloat64Array AeroSimNative::step_px4_actuator_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double motor_0,
        double motor_1,
        double motor_2,
        double motor_3) {
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_px4_actuator_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    const double values[] = {motor_0, motor_1, motor_2, motor_3};
    for (double value : values) {
        if (!std::isfinite(value) || value < 0.0 || value > 1.0) {
            set_step_error("step_px4_actuator_mode", aerosim::StepStatus::InvalidCommand, "motor command");
            return {};
        }
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    if (config.mass_kg <= 0.0 || !aerosim::validate_per_motor_config(config.per_motor)) {
        set_step_error("step_px4_actuator_mode", aerosim::StepStatus::InvalidConfig, "hardware");
        return {};
    }
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);
    const aerosim::MotorCommands commands{{motor_0, motor_1, motor_2, motor_3}};
    const aerosim::TrajectorySample sample = aerosim::step_per_motor_physics_frame(
            simulation_state_, simulation_clock_, config, commands);
    flight_controller_.publish_applied_telemetry(
            sample, config, (motor_0 + motor_1 + motor_2 + motor_3) * 0.25, "PX4_ACTUATOR");
    flight_mode_ = "PX4_ACTUATOR";
    PackedFloat64Array row;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    row.append(0.0);
    row.append(0.0);
    row.append(sample.state.angular_velocity.x);
    row.append(sample.state.angular_velocity.y);
    row.append(sample.state.angular_velocity.z);
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

PackedFloat64Array AeroSimNative::step_collision_px4_actuator_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double motor_0,
        double motor_1,
        double motor_2,
        double motor_3,
        bool touching,
        double normal_x,
        double normal_y,
        double normal_z,
        double impulse_x,
        double impulse_y,
        double impulse_z,
        double restitution,
        double resolved_velocity_x,
        double resolved_velocity_y,
        double resolved_velocity_z,
        double resolved_angular_velocity_x,
        double resolved_angular_velocity_y,
        double resolved_angular_velocity_z,
        double max_kinetic_energy_joules) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_collision_px4_actuator_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    const double values[] = {motor_0, motor_1, motor_2, motor_3};
    for (double value : values) {
        if (!std::isfinite(value) || value < 0.0 || value > 1.0) {
            set_step_error("step_collision_px4_actuator_mode", aerosim::StepStatus::InvalidCommand, "motor command");
            return {};
        }
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);
    aerosim::CollisionContact contact;
    contact.touching = touching;
    contact.normal = {normal_x, normal_y, normal_z};
    contact.impulse = {impulse_x, impulse_y, impulse_z};
    contact.restitution = restitution;
    contact.has_resolved_state = touching;
    contact.resolved_velocity = {resolved_velocity_x, resolved_velocity_y, resolved_velocity_z};
    contact.resolved_angular_velocity = {resolved_angular_velocity_x, resolved_angular_velocity_y, resolved_angular_velocity_z};
    contact.max_kinetic_energy_joules = max_kinetic_energy_joules;
    const aerosim::MotorCommands commands{{motor_0, motor_1, motor_2, motor_3}};
    const aerosim::CollisionStepResult result = collision_authority_.step_per_motor(
            simulation_state_, simulation_clock_, config, commands, contact);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_collision_px4_actuator_mode", result.status, "command/contact/config/state");
        return {};
    }
    if (result.authority == aerosim::PhysicsAuthority::Jolt) {
        flight_controller_.publish_unavailable_telemetry(result.sample, config, "PX4_ACTUATOR");
    } else {
        flight_controller_.publish_applied_telemetry(
                result.sample, config, (motor_0 + motor_1 + motor_2 + motor_3) * 0.25, "PX4_ACTUATOR");
    }
    if (result.sample.substeps == 0 && !touching && physics_hz > 0 && substep_hz > 0) {
        clear_step_error();
        return {};
    }
    flight_mode_ = "PX4_ACTUATOR";
    PackedFloat64Array row;
    const aerosim::TrajectorySample &sample = result.sample;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    row.append(result.authority == aerosim::PhysicsAuthority::Jolt ? 1.0 : 0.0);
    row.append(0.0);
    row.append(sample.state.angular_velocity.x);
    row.append(sample.state.angular_velocity.y);
    row.append(sample.state.angular_velocity.z);
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

bool AeroSimNative::arm_flight_control(double throttle) {
    return flight_controller_.arm(throttle);
}

void AeroSimNative::disarm_flight_control() {
    flight_controller_.disarm();
    simulation_state_.motor_thrust_newtons = {};
    flight_mode_ = "ANGLE";
    flight_control_used_estimated_attitude_ = false;
}

bool AeroSimNative::flight_control_armed() const {
    return flight_controller_.armed();
}

String AeroSimNative::flight_control_arm_reject_code() const {
    return flight_controller_.arm_reject_code().c_str();
}

double AeroSimNative::betaflight_stick_for_rate(
        double rate_degrees_per_second,
        double rc_rate,
        double super_rate,
        double expo) const {
    return aerosim::betaflight_stick_for_rate_degrees_per_second(
            rate_degrees_per_second,
            aerosim::RateProfile{rc_rate, super_rate, expo});
}

double AeroSimNative::betaflight_rate_for_stick(
        double stick,
        double rc_rate,
        double super_rate,
        double expo) const {
    if (!std::isfinite(stick) || !std::isfinite(rc_rate) || rc_rate < 0.0 || rc_rate > 3.0 ||
            !std::isfinite(super_rate) || super_rate < 0.0 || super_rate > 1.0 ||
            !std::isfinite(expo) || expo < 0.0 || expo > 1.0) {
        return 0.0;
    }
    return aerosim::betaflight_rate_degrees_per_second(
            stick,
            aerosim::RateProfile{rc_rate, super_rate, expo});
}

void AeroSimNative::reset_flight() {
    flight_controller_.reset_flight(simulation_state_, simulation_clock_);
    collision_authority_ = {};
    imu_.reset(imu_config_.seed);
    last_imu_sample_ = {};
    has_last_imu_sample_ = false;
    sample_imu();
    flight_control_used_estimated_attitude_ = false;
    flight_mode_ = "ANGLE";
    clear_step_error();
}

void AeroSimNative::capture_altitude_hold() {
    flight_controller_.capture_altitude_hold(simulation_state_.position.y);
    flight_mode_ = "ALTITUDE_HOLD";
}

void AeroSimNative::configure_imu(const Dictionary &config) {
    imu_noise_enabled_ = bool_value(config, "noise_enabled", imu_noise_enabled_);
    imu_bias_enabled_ = bool_value(config, "bias_enabled", imu_bias_enabled_);
    imu_random_walk_enabled_ = bool_value(config, "random_walk_enabled", imu_random_walk_enabled_);
    imu_delay_enabled_ = bool_value(config, "delay_enabled", imu_delay_enabled_);

    imu_config_.gyro_noise_density = imu_noise_enabled_ ? double_value(config, "gyro_noise_density", imu_config_.gyro_noise_density) : 0.0;
    imu_config_.accel_noise_density = imu_noise_enabled_ ? double_value(config, "accelerometer_noise_density", imu_config_.accel_noise_density) : 0.0;
    imu_config_.gyro_bias = imu_bias_enabled_ ? vec3_value(config, "gyro_bias", imu_config_.gyro_bias) : aerosim::Vec3{};
    imu_config_.accel_bias = imu_bias_enabled_ ? vec3_value(config, "accelerometer_bias", imu_config_.accel_bias) : aerosim::Vec3{};
    imu_config_.gyro_bias_drift_stddev = imu_bias_enabled_ ? double_value(config, "gyro_bias_drift", imu_config_.gyro_bias_drift_stddev) : 0.0;
    imu_config_.accel_bias_drift_stddev = imu_bias_enabled_ ? double_value(config, "accelerometer_bias_drift", imu_config_.accel_bias_drift_stddev) : 0.0;
    imu_config_.gyro_random_walk_stddev = imu_random_walk_enabled_ ? double_value(config, "gyro_random_walk", imu_config_.gyro_random_walk_stddev) : 0.0;
    imu_config_.accel_random_walk_stddev = imu_random_walk_enabled_ ? double_value(config, "accelerometer_random_walk", imu_config_.accel_random_walk_stddev) : 0.0;
    imu_config_.barometer_random_walk_stddev_m = imu_random_walk_enabled_ ? double_value(config, "barometer_random_walk", imu_config_.barometer_random_walk_stddev_m) : 0.0;
    imu_config_.barometer_noise_stddev_m = imu_noise_enabled_ ? double_value(config, "barometer_noise", imu_config_.barometer_noise_stddev_m) : 0.0;
    imu_config_.barometer_bias_drift_stddev_m = imu_bias_enabled_ ? double_value(config, "barometer_bias_drift", imu_config_.barometer_bias_drift_stddev_m) : 0.0;
    imu_config_.delay_samples = imu_delay_enabled_ ? int_value(config, "sample_delay_frames", imu_config_.delay_samples) : 0;
    imu_ = aerosim::ImuSimulator(imu_config_);
}

Dictionary AeroSimNative::imu_configuration() const {
    Dictionary config;
    config["noise_enabled"] = imu_noise_enabled_;
    config["bias_enabled"] = imu_bias_enabled_;
    config["random_walk_enabled"] = imu_random_walk_enabled_;
    config["delay_enabled"] = imu_delay_enabled_;
    config["gyro_noise_density"] = imu_config_.gyro_noise_density;
    config["accelerometer_noise_density"] = imu_config_.accel_noise_density;
    config["gyro_bias"] = godot_vec3(imu_config_.gyro_bias);
    config["accelerometer_bias"] = godot_vec3(imu_config_.accel_bias);
    config["gyro_bias_drift"] = imu_config_.gyro_bias_drift_stddev;
    config["accelerometer_bias_drift"] = imu_config_.accel_bias_drift_stddev;
    config["gyro_random_walk"] = imu_config_.gyro_random_walk_stddev;
    config["accelerometer_random_walk"] = imu_config_.accel_random_walk_stddev;
    config["barometer_noise"] = imu_config_.barometer_noise_stddev_m;
    config["barometer_bias_drift"] = imu_config_.barometer_bias_drift_stddev_m;
    config["barometer_random_walk"] = imu_config_.barometer_random_walk_stddev_m;
    config["sample_delay_frames"] = imu_config_.delay_samples;
    return config;
}

Dictionary AeroSimNative::imu_sample() const {
    Dictionary sample;
    sample["valid"] = has_last_imu_sample_;
    sample["time_seconds"] = last_imu_sample_.time_seconds;
    sample["gyro_x"] = last_imu_sample_.gyro_rad_per_s.x;
    sample["gyro_y"] = last_imu_sample_.gyro_rad_per_s.y;
    sample["gyro_z"] = last_imu_sample_.gyro_rad_per_s.z;
    sample["accel_x"] = last_imu_sample_.accel_mps2.x;
    sample["accel_y"] = last_imu_sample_.accel_mps2.y;
    sample["accel_z"] = last_imu_sample_.accel_mps2.z;
    sample["barometer_altitude_m"] = last_imu_sample_.barometer_altitude_m;
    sample["orientation_x"] = last_imu_sample_.estimated_attitude.x;
    sample["orientation_y"] = last_imu_sample_.estimated_attitude.y;
    sample["orientation_z"] = last_imu_sample_.estimated_attitude.z;
    sample["orientation_w"] = last_imu_sample_.estimated_attitude.w;
    sample["measurement_orientation_x"] = last_imu_sample_.measurement_attitude.x;
    sample["measurement_orientation_y"] = last_imu_sample_.measurement_attitude.y;
    sample["measurement_orientation_z"] = last_imu_sample_.measurement_attitude.z;
    sample["measurement_orientation_w"] = last_imu_sample_.measurement_attitude.w;
    return sample;
}

aerosim::ImuSample AeroSimNative::sample_imu() {
    last_imu_sample_ = imu_.sample(simulation_state_);
    has_last_imu_sample_ = true;
    return last_imu_sample_;
}

void AeroSimNative::refresh_imu_sample() {
    if (!valid_imu_state(simulation_state_)) {
        set_step_error("refresh_imu_sample", aerosim::StepStatus::InvalidState, "state");
        return;
    }
    sample_imu();
    clear_step_error();
}

String AeroSimNative::last_step_error() const {
    return last_step_error_;
}

void AeroSimNative::configure_wind(const Dictionary &config) {
    const String requested_preset = string_value(config, "preset", wind_preset_name_);
    if (config.has("preset") && !valid_wind_preset(requested_preset)) {
        return;
    }
    if (config.has("steady_wind") && config["steady_wind"].get_type() != Variant::VECTOR3) {
        return;
    }
    const aerosim::Vec3 steady_wind = vec3_value(config, "steady_wind", wind_field_.steady_wind());
    if (!std::isfinite(steady_wind.x) || !std::isfinite(steady_wind.y) || !std::isfinite(steady_wind.z)) {
        return;
    }
    wind_preset_name_ = requested_preset;
    aerosim::WindConfig wind_config = preset_config(wind_preset_name_);
    wind_config.steady_wind_mps = steady_wind;
    wind_config.turbulence_sigma_mps = vec3_value(config, "turbulence_sigma", wind_config.turbulence_sigma_mps);
    wind_config.reference_airspeed_mps = double_value(config, "reference_airspeed_mps", wind_config.reference_airspeed_mps);
    wind_config.scale_length_m = double_value(config, "scale_length_m", wind_config.scale_length_m);
    wind_config.shear_reference_height_m = double_value(config, "shear_reference_height_m", wind_config.shear_reference_height_m);
    wind_config.shear_exponent = double_value(config, "shear_exponent", wind_config.shear_exponent);
    wind_config.shear_enabled = bool_value(config, "shear_enabled", wind_config.shear_enabled);
    const std::int32_t seed = int_value(config, "seed", static_cast<std::int32_t>(wind_config.seed));
    if (seed < 0 || !std::isfinite(wind_config.reference_airspeed_mps) || wind_config.reference_airspeed_mps <= 0.0 ||
            !std::isfinite(wind_config.scale_length_m) || wind_config.scale_length_m <= 0.0 ||
            !std::isfinite(wind_config.shear_reference_height_m) || wind_config.shear_reference_height_m <= 0.0 ||
            !std::isfinite(wind_config.shear_exponent) || wind_config.shear_exponent < 0.0 ||
            !std::isfinite(wind_config.turbulence_sigma_mps.x) || !std::isfinite(wind_config.turbulence_sigma_mps.y) ||
            !std::isfinite(wind_config.turbulence_sigma_mps.z) || wind_config.turbulence_sigma_mps.x < 0.0 ||
            wind_config.turbulence_sigma_mps.y < 0.0 || wind_config.turbulence_sigma_mps.z < 0.0) {
        return;
    }
    wind_config.seed = static_cast<std::uint32_t>(seed);
    wind_field_.configure(wind_config);
}

Dictionary AeroSimNative::wind_configuration() const {
    const aerosim::WindConfig &wind_config = wind_field_.config();
    Dictionary config;
    config["preset"] = wind_preset_name_;
    config["steady_wind"] = godot_vec3(wind_config.steady_wind_mps);
    config["turbulence_sigma"] = godot_vec3(wind_config.turbulence_sigma_mps);
    config["reference_airspeed_mps"] = wind_config.reference_airspeed_mps;
    config["scale_length_m"] = wind_config.scale_length_m;
    config["shear_reference_height_m"] = wind_config.shear_reference_height_m;
    config["shear_exponent"] = wind_config.shear_exponent;
    config["shear_enabled"] = wind_config.shear_enabled;
    config["seed"] = static_cast<std::int32_t>(wind_config.seed);
    return config;
}

Vector3 AeroSimNative::sample_wind(double time_seconds, double position_x, double position_y, double position_z) const {
    return godot_vec3(wind_field_.sample(time_seconds, {position_x, position_y, position_z}));
}

Dictionary AeroSimNative::flight_control_diagnostics() const {
    Dictionary diagnostics;
    diagnostics["uses_estimated_attitude"] = flight_control_used_estimated_attitude_;
    diagnostics["flight_mode"] = flight_mode_;
    const aerosim::PidTimingStats &timing = flight_controller_.pid_timing_stats();
    diagnostics["pid_target_hz"] = timing.target_hz;
    diagnostics["pid_p99_jitter_fraction"] = timing.p99_jitter_fraction;
    diagnostics["pid_samples"] = static_cast<double>(timing.samples);
    diagnostics["motor_thrust_newtons"] = flight_controller_.motor_thrust_newtons();
    diagnostics["angular_velocity_x_rad_s"] = simulation_state_.angular_velocity.x;
    diagnostics["angular_velocity_y_rad_s"] = simulation_state_.angular_velocity.y;
    diagnostics["angular_velocity_z_rad_s"] = simulation_state_.angular_velocity.z;
    return diagnostics;
}

Dictionary AeroSimNative::hardware_power_diagnostics() const {
    const aerosim::SimulationConfig config = hardware_config_.simulation_config();
    Dictionary diagnostics;
    diagnostics["mass_kg"] = config.mass_kg;
    diagnostics["hover_throttle"] = config.hover_throttle;
    diagnostics["max_total_thrust_newtons"] = config.max_total_thrust_newtons;
    diagnostics["full_throttle_cap_newtons"] = aerosim::available_thrust_cap_newtons(config, 1.0);
    diagnostics["hover_throttle_cap_newtons"] = aerosim::available_thrust_cap_newtons(config, config.hover_throttle);
    diagnostics["battery_nominal_voltage_v"] = config.battery_nominal_voltage_v;
    diagnostics["battery_cell_resistance_ohm"] = config.battery_cell_resistance_ohm;
    diagnostics["max_total_current_a"] = config.max_total_current_a;
    diagnostics["max_motor_rpm"] = config.max_motor_rpm;
    diagnostics["battery_remaining_mah"] = config.battery_remaining_mah;
    return diagnostics;
}

Dictionary AeroSimNative::hardware_per_motor_diagnostics() const {
    const aerosim::PerMotorPhysicsConfig &per_motor = hardware_config_.simulation_config().per_motor;
    Dictionary diagnostics;
    Array motor_order;
    motor_order.append("rear_right");
    motor_order.append("front_right");
    motor_order.append("rear_left");
    motor_order.append("front_left");
    diagnostics["motor_order"] = motor_order;
    Array spin_direction;
    for (double spin : per_motor.spin_direction) {
        spin_direction.append(spin > 0.0 ? "cw" : "ccw");
    }
    diagnostics["spin_direction"] = spin_direction;
    diagnostics["inertia_frd"] = godot_vec3(per_motor.inertia_kg_m2);
    diagnostics["max_thrust_per_motor_newtons"] = per_motor.max_thrust_per_motor_newtons;
    diagnostics["max_current_per_motor_a"] = per_motor.max_current_per_motor_a;
    diagnostics["yaw_torque_per_newton"] = per_motor.yaw_torque_per_newton;
    return diagnostics;
}

Dictionary AeroSimNative::telemetry_snapshot() const {
    const aerosim::TelemetrySnapshot &snapshot = flight_controller_.telemetry_snapshot();
    Dictionary dict;
    dict["schema_version"] = snapshot.schema_version;
    dict["timestamp_us"] = static_cast<std::int64_t>(snapshot.timestamp_us);
    dict["publish_count"] = static_cast<std::int64_t>(snapshot.publish_count);
    dict["snapshot_hz"] = snapshot.snapshot_hz;
    dict["vehicle_id"] = snapshot.vehicle_id.c_str();
    dict["world_frame"] = snapshot.world_frame.c_str();
    dict["body_frame"] = snapshot.body_frame.c_str();
    dict["units"] = snapshot.units.c_str();
    dict["coordinate_frame"] = "FRD";
    Array motor_order;
    motor_order.append("rear_right");
    motor_order.append("front_right");
    motor_order.append("rear_left");
    motor_order.append("front_left");
    dict["motor_order"] = motor_order;
    dict["motor_order_standard"] = "Betaflight quad-X 1-4";
    Array motors;
    for (const aerosim::MotorTelemetry &motor : snapshot.motors) {
        motors.append(motor_telemetry_dict(motor));
    }
    dict["motors"] = motors;
    dict["wind_world_mps"] = godot_vec3(snapshot.wind_world_mps);
    dict["wind_body_mps"] = godot_vec3(snapshot.wind_body_mps);
    dict["turbulence_intensity"] = snapshot.turbulence_intensity;
    dict["ground_effect_gain"] = snapshot.ground_effect_gain;
    dict["downwash_force_n"] = snapshot.downwash_force_n;
    dict["propwash_disturbance_rad_s2"] = godot_vec3(snapshot.propwash_disturbance_rad_s2);
    dict["drag_body_n"] = godot_vec3(snapshot.drag_body_n);
    dict["air_density_kg_m3"] = snapshot.air_density_kg_m3;
    dict["airspeed_body_frd_mps_mean"] = godot_vec3(snapshot.airspeed_body_frd_mps_mean);
    dict["body_drag_force_body_frd_n_mean"] = finite_vec3(snapshot.body_drag_force_body_frd_n_mean)
            ? Variant(godot_vec3(snapshot.body_drag_force_body_frd_n_mean)) : Variant();
    dict["body_drag_torque_body_frd_nm_mean"] = finite_vec3(snapshot.body_drag_torque_body_frd_nm_mean)
            ? Variant(godot_vec3(snapshot.body_drag_torque_body_frd_nm_mean)) : Variant();
    dict["a3_drag_force_body_frd_n_mean"] = godot_vec3(snapshot.a3_drag_force_body_frd_n_mean);
    dict["a6_angular_accel_body_frd_rad_s2"] = godot_vec3(snapshot.a6_angular_accel_body_frd_rad_s2);
    dict["body_drag_operating_state"] = snapshot.body_drag_operating_state.c_str();
    dict["body_drag_evidence_state"] = snapshot.body_drag_evidence_state.c_str();
    dict["body_drag_reason_code"] = snapshot.body_drag_reason_code.c_str();
    dict["a3_operating_state"] = snapshot.a3_operating_state.c_str();
    dict["a6_operating_state"] = snapshot.a6_operating_state.c_str();
    dict["config_hash"] = snapshot.config_hash.c_str();
    Dictionary battery;
    battery["voltage_v"] = snapshot.battery.voltage_v;
    battery["sag_v"] = snapshot.battery.sag_v;
    battery["remaining_mah"] = snapshot.battery.remaining_mah;
    dict["battery"] = battery;
    Array pid;
    for (const aerosim::PidAxisTelemetry &axis : snapshot.pid) {
        pid.append(pid_telemetry_dict(axis, snapshot.pid_available));
    }
    dict["pid"] = pid;
    dict["control_authority"] = snapshot.control_authority.c_str();
    dict["armed_available"] = snapshot.armed_available;
    dict["pid_available"] = snapshot.pid_available;
    dict["armed"] = snapshot.armed_available ? Variant(snapshot.armed) : Variant();
    dict["mode"] = snapshot.mode.c_str();
    dict["source"] = "native_double_buffer";
    return dict;
}

bool AeroSimNative::set_a3_drag_model(
        bool enabled,
        double coefficient_x_kg,
        double coefficient_y_kg,
        double coefficient_z_kg) {
    const double values[] = {
            coefficient_x_kg,
            coefficient_y_kg,
            coefficient_z_kg,
    };
    for (double value : values) {
        if (!std::isfinite(value) || value < 0.0) {
            return false;
        }
    }
    return hardware_config_.set_a3_drag_model(
            enabled, {coefficient_x_kg, coefficient_y_kg, coefficient_z_kg});
}

Dictionary AeroSimNative::a3_drag_configuration() const {
    Dictionary config;
    const aerosim::A3DragConfig &a3_drag = hardware_config_.a3_drag;
    config["enabled"] = a3_drag.enabled;
    config["coefficient_x_kg"] = a3_drag.coefficient.x;
    config["coefficient_y_kg"] = a3_drag.coefficient.y;
    config["coefficient_z_kg"] = a3_drag.coefficient.z;
    config["motor_speed_source"] = "live_motor_thrust_state";
    return config;
}

bool AeroSimNative::set_body_drag_model(
        bool enabled,
        double coefficient_x,
        double coefficient_y,
        double coefficient_z,
        double frontal_area_x_m2,
        double frontal_area_y_m2,
        double frontal_area_z_m2,
        double center_of_pressure_x_m,
        double center_of_pressure_y_m,
        double center_of_pressure_z_m,
        double air_density_kg_m3) {
    const aerosim::BodyDragConfig config{
            enabled,
            {coefficient_x, coefficient_y, coefficient_z},
            {frontal_area_x_m2, frontal_area_y_m2, frontal_area_z_m2},
            {center_of_pressure_x_m, center_of_pressure_y_m, center_of_pressure_z_m},
    };
    return hardware_config_.set_body_drag_model(enabled, config, air_density_kg_m3);
}

bool AeroSimNative::set_config_hash(const String &config_hash) {
    if (config_hash.is_empty()) {
        return false;
    }
    hardware_config_.config_hash = config_hash.utf8().get_data();
    return true;
}

String AeroSimNative::config_hash() const {
    return hardware_config_.config_hash.c_str();
}

Dictionary AeroSimNative::body_drag_configuration() const {
    const aerosim::BodyDragConfig &body_drag = hardware_config_.body_drag;
    Dictionary config;
    config["enabled"] = body_drag.enabled;
    config["drag_coefficient"] = godot_vec3(body_drag.drag_coefficient);
    config["frontal_area_m2"] = godot_vec3(body_drag.frontal_area_m2);
    config["center_of_pressure_frd_m"] = godot_vec3(body_drag.center_of_pressure_frd_m);
    config["air_density_kg_m3"] = hardware_config_.air_density_kg_m3;
    config["evidence_state"] = "provisional";
    return config;
}

bool AeroSimNative::set_a6_propwash_model(
        bool enabled,
        double full_collective_angular_accel_rad_s2,
        double minimum_wake_entry_speed_mps,
        double minimum_transverse_rate_rad_s) {
    const aerosim::A6PropwashConfig config{
            enabled,
            full_collective_angular_accel_rad_s2,
            minimum_wake_entry_speed_mps,
            minimum_transverse_rate_rad_s,
    };
    if (!hardware_config_.set_a6_propwash_model(enabled, config)) {
        return false;
    }
    if (!enabled) {
        flight_controller_.clear_propwash_telemetry();
    }
    return true;
}

Dictionary AeroSimNative::a6_propwash_configuration() const {
    Dictionary config;
    const aerosim::A6PropwashConfig &a6 = hardware_config_.a6_propwash;
    config["enabled"] = a6.enabled;
    config["full_collective_angular_accel_rad_s2"] = a6.full_collective_angular_accel_rad_s2;
    config["minimum_wake_entry_speed_mps"] = a6.minimum_wake_entry_speed_mps;
    config["minimum_transverse_rate_rad_s"] = a6.minimum_transverse_rate_rad_s;
    return config;
}

bool AeroSimNative::set_a4_ground_effect_model(
        bool enabled,
        double kf,
        double ground_effect_coeff,
        double prop_radius_m,
        double height_clip_m,
        double motor_0_rpm,
        double motor_1_rpm,
        double motor_2_rpm,
        double motor_3_rpm) {
    const double values[] = {
            kf,
            ground_effect_coeff,
            prop_radius_m,
            height_clip_m,
            motor_0_rpm,
            motor_1_rpm,
            motor_2_rpm,
            motor_3_rpm,
    };
    for (double value : values) {
        if (!std::isfinite(value) || value < 0.0) {
            return false;
        }
    }
    if (prop_radius_m == 0.0 || height_clip_m == 0.0) {
        return false;
    }
    a4_ground_effect_config_.enabled = enabled;
    a4_ground_effect_config_.kf = kf;
    a4_ground_effect_config_.ground_effect_coeff = ground_effect_coeff;
    a4_ground_effect_config_.prop_radius_m = prop_radius_m;
    a4_ground_effect_config_.height_clip_m = height_clip_m;
    a4_ground_effect_config_.motor_rpm = {motor_0_rpm, motor_1_rpm, motor_2_rpm, motor_3_rpm};
    return true;
}

Dictionary AeroSimNative::a4_ground_effect_configuration() const {
    Dictionary config;
    config["enabled"] = a4_ground_effect_config_.enabled;
    config["kf"] = a4_ground_effect_config_.kf;
    config["ground_effect_coeff"] = a4_ground_effect_config_.ground_effect_coeff;
    config["prop_radius_m"] = a4_ground_effect_config_.prop_radius_m;
    config["height_clip_m"] = a4_ground_effect_config_.height_clip_m;
    config["motor_0_rpm"] = a4_ground_effect_config_.motor_rpm[0];
    config["motor_1_rpm"] = a4_ground_effect_config_.motor_rpm[1];
    config["motor_2_rpm"] = a4_ground_effect_config_.motor_rpm[2];
    config["motor_3_rpm"] = a4_ground_effect_config_.motor_rpm[3];
    return config;
}

bool AeroSimNative::set_a5_downwash_model(
        bool enabled,
        double prop_radius_m,
        double coeff_1,
        double coeff_2,
        double coeff_3) {
    const double values[] = {prop_radius_m, coeff_1, coeff_2, coeff_3};
    for (double value : values) {
        if (!std::isfinite(value)) {
            return false;
        }
    }
    if (prop_radius_m <= 0.0) {
        return false;
    }
    if (coeff_1 < 0.0) {
        return false;
    }
    a5_downwash_config_.enabled = enabled;
    a5_downwash_config_.prop_radius_m = prop_radius_m;
    a5_downwash_config_.coeff_1 = coeff_1;
    a5_downwash_config_.coeff_2 = coeff_2;
    a5_downwash_config_.coeff_3 = coeff_3;
    return true;
}

Dictionary AeroSimNative::a5_downwash_configuration() const {
    Dictionary config;
    config["enabled"] = a5_downwash_config_.enabled;
    config["prop_radius_m"] = a5_downwash_config_.prop_radius_m;
    config["coeff_1"] = a5_downwash_config_.coeff_1;
    config["coeff_2"] = a5_downwash_config_.coeff_2;
    config["coeff_3"] = a5_downwash_config_.coeff_3;
    return config;
}

double AeroSimNative::a5_downwash_force_y(
        double upper_x,
        double upper_y,
        double upper_z,
        double lower_x,
        double lower_y,
        double lower_z) const {
    return aerosim::a5_downwash_force_y_newtons(
            a5_downwash_config_,
            {upper_x, upper_y, upper_z},
            {lower_x, lower_y, lower_z});
}

void AeroSimNative::set_collision_release_frames(std::int32_t release_frames) {
    collision_authority_.set_release_frames(release_frames);
}

void AeroSimNative::sync_flight_state(
        double position_x,
        double position_y,
        double position_z,
        double orientation_x,
        double orientation_y,
        double orientation_z,
        double orientation_w,
        double velocity_x,
        double velocity_y,
        double velocity_z,
        double angular_velocity_x,
        double angular_velocity_y,
        double angular_velocity_z) {
    aerosim::RigidBodyState candidate;
    candidate.position = {position_x, position_y, position_z};
    candidate.orientation = {orientation_x, orientation_y, orientation_z, orientation_w};
    candidate.velocity = {velocity_x, velocity_y, velocity_z};
    candidate.angular_velocity = {angular_velocity_x, angular_velocity_y, angular_velocity_z};
    if (!valid_imu_state(candidate)) {
        set_step_error("sync_flight_state", aerosim::StepStatus::InvalidState, "state");
        return;
    }
    simulation_state_.position = candidate.position;
    simulation_state_.orientation = candidate.orientation;
    simulation_state_.velocity = candidate.velocity;
    simulation_state_.angular_velocity = candidate.angular_velocity;
    clear_step_error();
}

PackedFloat64Array AeroSimNative::step_angle_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_angle_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    const aerosim::StepStatus input_status = aerosim::validate_angle_step_inputs(
            simulation_state_, simulation_clock_, config, command, simulation_state_.orientation);
    if (input_status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_angle_mode", input_status, "command/config/state");
        return {};
    }

    PackedFloat64Array row;
    const aerosim::ImuSample imu_sample = sample_imu();
    const aerosim::StepResult result = flight_controller_.try_step_angle_mode(
            simulation_state_,
            simulation_clock_,
            config,
            command,
            imu_sample.estimated_attitude);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_angle_mode", result.status, "command/config/state");
        return {};
    }
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ANGLE";
    const aerosim::TrajectorySample &sample = result.sample;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

PackedFloat64Array AeroSimNative::step_acro_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_stick,
        double pitch_stick,
        double yaw_stick,
        double rc_rate,
        double super_rate,
        double expo) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_acro_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    aerosim::AcroCommand command;
    command.throttle = throttle;
    command.roll_stick = roll_stick;
    command.pitch_stick = pitch_stick;
    command.yaw_stick = yaw_stick;
    command.rates = {rc_rate, super_rate, expo};

    const aerosim::StepStatus input_status = aerosim::validate_acro_step_inputs(
            simulation_state_, simulation_clock_, config, command);
    if (input_status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_acro_mode", input_status, "command/config/state");
        return {};
    }

    sample_imu();
    const aerosim::StepResult result = flight_controller_.try_step_acro_mode(
            simulation_state_,
            simulation_clock_,
            config,
            command);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_acro_mode", result.status, "command/config/state");
        return {};
    }
    flight_mode_ = "ACRO";
    const aerosim::TrajectorySample &sample = result.sample;

    PackedFloat64Array row;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

PackedFloat64Array AeroSimNative::step_collision_angle_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second,
        bool touching,
        double normal_x,
        double normal_y,
        double normal_z,
        double impulse_x,
        double impulse_y,
        double impulse_z,
        double restitution,
        double resolved_velocity_x,
        double resolved_velocity_y,
        double resolved_velocity_z,
        double resolved_angular_velocity_x,
        double resolved_angular_velocity_y,
        double resolved_angular_velocity_z,
        double max_kinetic_energy_joules) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_collision_angle_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    aerosim::CollisionContact contact;
    contact.touching = touching;
    contact.normal = {normal_x, normal_y, normal_z};
    contact.impulse = {impulse_x, impulse_y, impulse_z};
    contact.restitution = restitution;
    contact.has_resolved_state = touching;
    contact.resolved_velocity = {resolved_velocity_x, resolved_velocity_y, resolved_velocity_z};
    contact.resolved_angular_velocity = {resolved_angular_velocity_x, resolved_angular_velocity_y, resolved_angular_velocity_z};
    contact.max_kinetic_energy_joules = max_kinetic_energy_joules;
    const aerosim::StepStatus input_status = aerosim::validate_angle_step_inputs(
            simulation_state_, simulation_clock_, config, command, simulation_state_.orientation);
    if (input_status != aerosim::StepStatus::Ok || !aerosim::valid_collision_contact(contact)) {
        restore_step(snapshot);
        set_step_error("step_collision_angle_mode", input_status == aerosim::StepStatus::Ok
                ? aerosim::StepStatus::InvalidCommand : input_status, "command/contact/config/state");
        return {};
    }

    const aerosim::ImuSample imu_sample = sample_imu();
    const aerosim::CollisionStepResult result = collision_authority_.step(
            simulation_state_,
            simulation_clock_,
            flight_controller_,
            config,
            command,
            contact,
            imu_sample.estimated_attitude);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_collision_angle_mode", result.status, "command/contact/config/state");
        return {};
    }
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ANGLE";
    if (result.authority == aerosim::PhysicsAuthority::Jolt) {
        flight_controller_.publish_unavailable_telemetry(result.sample, config, "ANGLE");
    }

    PackedFloat64Array row;
    const aerosim::TrajectorySample &sample = result.sample;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    row.append(result.authority == aerosim::PhysicsAuthority::Jolt ? 1.0 : 0.0);
    row.append(static_cast<double>(flight_controller_.integrator_reset_count()));
    row.append(sample.state.angular_velocity.x);
    row.append(sample.state.angular_velocity.y);
    row.append(sample.state.angular_velocity.z);
    row.append(aerosim::kinetic_energy_joules(sample.state, config.mass_kg));
    row.append(result.normal.x);
    row.append(result.normal.y);
    row.append(result.normal.z);
    row.append(result.impulse.x);
    row.append(result.impulse.y);
    row.append(result.impulse.z);
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

PackedFloat64Array AeroSimNative::step_altitude_hold_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_altitude_hold_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    const aerosim::StepStatus input_status = aerosim::validate_altitude_hold_step_inputs(
            simulation_state_, simulation_clock_, config, command, 0.0, simulation_state_.orientation);
    if (input_status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_altitude_hold_mode", input_status, "command/config/state");
        return {};
    }

    PackedFloat64Array row;
    const aerosim::ImuSample imu_sample = sample_imu();
    const aerosim::StepResult result = flight_controller_.try_step_altitude_hold_mode(
            simulation_state_,
            simulation_clock_,
            config,
            command,
            imu_sample.barometer_altitude_m,
            imu_sample.estimated_attitude);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_altitude_hold_mode", result.status, "command/config/state");
        return {};
    }
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ALTITUDE_HOLD";
    const aerosim::TrajectorySample &sample = result.sample;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

PackedFloat64Array AeroSimNative::simulate_trajectory(
        double seconds,
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double total_thrust_newtons) const {
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.seconds = seconds;
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.total_thrust_newtons = flight_controller_.armed() ? total_thrust_newtons : 0.0;
    if (flight_controller_.armed()) {
        config.initial_state.motor_thrust_newtons.fill(total_thrust_newtons / 4.0);
    } else {
        config.initial_state.motor_thrust_newtons = {};
    }
    config.a4_ground_effect = a4_ground_effect_config_;

    PackedFloat64Array rows;
    if (config.seconds <= 0.0 || config.physics_hz <= 0 || config.substep_hz <= 0 || config.mass_kg <= 0.0) {
        return rows;
    }
    aerosim::RigidBodyState state = config.initial_state;
    aerosim::SimulationClock clock;
    const auto physics_frames = static_cast<std::int32_t>(std::ceil(config.seconds * config.physics_hz));
    for (std::int32_t frame = 0; frame < physics_frames; ++frame) {
        apply_wind(config, state, clock, wind_field_);
        const aerosim::TrajectorySample sample = aerosim::step_physics_frame(state, clock, config);
        rows.append(sample.time_seconds);
        rows.append(sample.state.position.x);
        rows.append(sample.state.position.y);
        rows.append(sample.state.position.z);
        rows.append(sample.state.orientation.x);
        rows.append(sample.state.orientation.y);
        rows.append(sample.state.orientation.z);
        rows.append(sample.state.orientation.w);
        rows.append(sample.state.velocity.x);
        rows.append(sample.state.velocity.y);
        rows.append(sample.state.velocity.z);
        rows.append(static_cast<double>(sample.substeps));
    }
    return rows;
}

PackedFloat64Array AeroSimNative::step_collision_acro_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_stick,
        double pitch_stick,
        double yaw_stick,
        double rc_rate,
        double super_rate,
        double expo,
        bool touching,
        double normal_x,
        double normal_y,
        double normal_z,
        double impulse_x,
        double impulse_y,
        double impulse_z,
        double restitution,
        double resolved_velocity_x,
        double resolved_velocity_y,
        double resolved_velocity_z,
        double resolved_angular_velocity_x,
        double resolved_angular_velocity_y,
        double resolved_angular_velocity_z,
        double max_kinetic_energy_joules) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_collision_acro_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    aerosim::AcroCommand command;
    command.throttle = throttle;
    command.roll_stick = roll_stick;
    command.pitch_stick = pitch_stick;
    command.yaw_stick = yaw_stick;
    command.rates = {rc_rate, super_rate, expo};

    aerosim::CollisionContact contact;
    contact.touching = touching;
    contact.normal = {normal_x, normal_y, normal_z};
    contact.impulse = {impulse_x, impulse_y, impulse_z};
    contact.restitution = restitution;
    contact.has_resolved_state = touching;
    contact.resolved_velocity = {resolved_velocity_x, resolved_velocity_y, resolved_velocity_z};
    contact.resolved_angular_velocity = {resolved_angular_velocity_x, resolved_angular_velocity_y, resolved_angular_velocity_z};
    contact.max_kinetic_energy_joules = max_kinetic_energy_joules;
    const aerosim::StepStatus input_status = aerosim::validate_acro_step_inputs(
            simulation_state_, simulation_clock_, config, command);
    if (input_status != aerosim::StepStatus::Ok || !aerosim::valid_collision_contact(contact)) {
        restore_step(snapshot);
        set_step_error("step_collision_acro_mode", input_status == aerosim::StepStatus::Ok
                ? aerosim::StepStatus::InvalidCommand : input_status, "command/contact/config/state");
        return {};
    }

    sample_imu();
    const aerosim::CollisionStepResult result = collision_authority_.step_acro(
            simulation_state_,
            simulation_clock_,
            flight_controller_,
            config,
            command,
            contact);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_collision_acro_mode", result.status, "command/contact/config/state");
        return {};
    }
    flight_mode_ = "ACRO";
    if (result.authority == aerosim::PhysicsAuthority::Jolt) {
        flight_controller_.publish_unavailable_telemetry(result.sample, config, "ACRO");
    }

    PackedFloat64Array row;
    const aerosim::TrajectorySample &sample = result.sample;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    row.append(result.authority == aerosim::PhysicsAuthority::Jolt ? 1.0 : 0.0);
    row.append(static_cast<double>(flight_controller_.integrator_reset_count()));
    row.append(sample.state.angular_velocity.x);
    row.append(sample.state.angular_velocity.y);
    row.append(sample.state.angular_velocity.z);
    row.append(aerosim::kinetic_energy_joules(sample.state, config.mass_kg));
    row.append(result.normal.x);
    row.append(result.normal.y);
    row.append(result.normal.z);
    row.append(result.impulse.x);
    row.append(result.impulse.y);
    row.append(result.impulse.z);
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}

PackedFloat64Array AeroSimNative::step_collision_altitude_hold_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second,
        bool touching,
        double normal_x,
        double normal_y,
        double normal_z,
        double impulse_x,
        double impulse_y,
        double impulse_z,
        double restitution,
        double resolved_velocity_x,
        double resolved_velocity_y,
        double resolved_velocity_z,
        double resolved_angular_velocity_x,
        double resolved_angular_velocity_y,
        double resolved_angular_velocity_z,
        double max_kinetic_energy_joules) {
    const StepSnapshot snapshot = snapshot_step();
    if (physics_hz <= 0 || substep_hz <= 0) {
        set_step_error("step_collision_altitude_hold_mode", aerosim::StepStatus::InvalidConfig, "timing");
        return {};
    }
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a4_ground_effect = a4_ground_effect_config_;
    config.external_force_world = external_force_world_;
    apply_downwash_provider(config);
    apply_wind(config, simulation_state_, simulation_clock_, wind_field_);

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    aerosim::CollisionContact contact;
    contact.touching = touching;
    contact.normal = {normal_x, normal_y, normal_z};
    contact.impulse = {impulse_x, impulse_y, impulse_z};
    contact.restitution = restitution;
    contact.has_resolved_state = touching;
    contact.resolved_velocity = {resolved_velocity_x, resolved_velocity_y, resolved_velocity_z};
    contact.resolved_angular_velocity = {resolved_angular_velocity_x, resolved_angular_velocity_y, resolved_angular_velocity_z};
    contact.max_kinetic_energy_joules = max_kinetic_energy_joules;
    const aerosim::StepStatus input_status = aerosim::validate_altitude_hold_step_inputs(
            simulation_state_, simulation_clock_, config, command, 0.0, simulation_state_.orientation);
    if (input_status != aerosim::StepStatus::Ok || !aerosim::valid_collision_contact(contact)) {
        restore_step(snapshot);
        set_step_error("step_collision_altitude_hold_mode", input_status == aerosim::StepStatus::Ok
                ? aerosim::StepStatus::InvalidCommand : input_status, "command/contact/config/state");
        return {};
    }

    const aerosim::ImuSample imu_sample = sample_imu();
    const aerosim::CollisionStepResult result = collision_authority_.step_altitude_hold(
            simulation_state_,
            simulation_clock_,
            flight_controller_,
            config,
            command,
            imu_sample.barometer_altitude_m,
            contact,
            imu_sample.estimated_attitude);
    if (result.status != aerosim::StepStatus::Ok) {
        restore_step(snapshot);
        set_step_error("step_collision_altitude_hold_mode", result.status, "command/contact/config/state");
        return {};
    }
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ALTITUDE_HOLD";
    if (result.authority == aerosim::PhysicsAuthority::Jolt) {
        flight_controller_.publish_unavailable_telemetry(result.sample, config, "ALTITUDE_HOLD");
    }

    PackedFloat64Array row;
    const aerosim::TrajectorySample &sample = result.sample;
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    row.append(result.authority == aerosim::PhysicsAuthority::Jolt ? 1.0 : 0.0);
    row.append(static_cast<double>(flight_controller_.integrator_reset_count()));
    row.append(sample.state.angular_velocity.x);
    row.append(sample.state.angular_velocity.y);
    row.append(sample.state.angular_velocity.z);
    row.append(aerosim::kinetic_energy_joules(sample.state, config.mass_kg));
    row.append(result.normal.x);
    row.append(result.normal.y);
    row.append(result.normal.z);
    row.append(result.impulse.x);
    row.append(result.impulse.y);
    row.append(result.impulse.z);
    capture_replay_first_response(sample);
    clear_step_error();
    return row;
}
