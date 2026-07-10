#include "aerosim_native.hpp"

#include "aerosim_aerodynamics.hpp"
#include "aerosim_probe.hpp"
#include <cmath>
#include <godot_cpp/core/class_db.hpp>
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
    if (!dict.has(key)) {
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

Vector3 godot_vec3(const aerosim::Vec3 &value) {
    return {static_cast<real_t>(value.x), static_cast<real_t>(value.y), static_cast<real_t>(value.z)};
}

Dictionary motor_telemetry_dict(const aerosim::MotorTelemetry &motor) {
    Dictionary dict;
    dict["thrust_newtons"] = motor.thrust_newtons;
    dict["speed_rad_s"] = motor.speed_rad_s;
    dict["current_a"] = motor.current_a;
    dict["saturated"] = motor.saturated;
    return dict;
}

Dictionary pid_telemetry_dict(const aerosim::PidAxisTelemetry &axis) {
    Dictionary dict;
    dict["output"] = axis.output;
    dict["saturated"] = axis.saturated;
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
    ClassDB::bind_method(D_METHOD("reset_simulation"), &AeroSimNative::reset_simulation);
    ClassDB::bind_method(
            D_METHOD("step_simulation", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::step_simulation);
    ClassDB::bind_method(D_METHOD("arm_flight_control", "throttle"), &AeroSimNative::arm_flight_control);
    ClassDB::bind_method(D_METHOD("flight_control_armed"), &AeroSimNative::flight_control_armed);
    ClassDB::bind_method(D_METHOD("flight_control_arm_reject_code"), &AeroSimNative::flight_control_arm_reject_code);
    ClassDB::bind_method(D_METHOD("reset_flight"), &AeroSimNative::reset_flight);
    ClassDB::bind_method(D_METHOD("capture_altitude_hold"), &AeroSimNative::capture_altitude_hold);
    ClassDB::bind_method(D_METHOD("configure_imu", "config"), &AeroSimNative::configure_imu);
    ClassDB::bind_method(D_METHOD("imu_configuration"), &AeroSimNative::imu_configuration);
    ClassDB::bind_method(D_METHOD("flight_control_diagnostics"), &AeroSimNative::flight_control_diagnostics);
    ClassDB::bind_method(D_METHOD("hardware_power_diagnostics"), &AeroSimNative::hardware_power_diagnostics);
    ClassDB::bind_method(D_METHOD("hardware_per_motor_diagnostics"), &AeroSimNative::hardware_per_motor_diagnostics);
    ClassDB::bind_method(D_METHOD("telemetry_snapshot"), &AeroSimNative::telemetry_snapshot);
    ClassDB::bind_method(
            D_METHOD("set_a3_drag_model", "enabled", "coefficient_x", "coefficient_y", "coefficient_z", "motor_0_rpm", "motor_1_rpm", "motor_2_rpm", "motor_3_rpm"),
            &AeroSimNative::set_a3_drag_model);
    ClassDB::bind_method(D_METHOD("a3_drag_configuration"), &AeroSimNative::a3_drag_configuration);
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
    collision_authority_ = {};
}

PackedFloat64Array AeroSimNative::step_simulation(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double total_thrust_newtons) {
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.total_thrust_newtons = flight_controller_.armed() ? total_thrust_newtons : 0.0;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

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

bool AeroSimNative::arm_flight_control(double throttle) {
    return flight_controller_.arm(throttle);
}

bool AeroSimNative::flight_control_armed() const {
    return flight_controller_.armed();
}

String AeroSimNative::flight_control_arm_reject_code() const {
    return flight_controller_.arm_reject_code().c_str();
}

void AeroSimNative::reset_flight() {
    flight_controller_.reset_flight(simulation_state_, simulation_clock_);
    collision_authority_ = {};
    imu_.reset(imu_config_.seed);
    flight_control_used_estimated_attitude_ = false;
    flight_mode_ = "ANGLE";
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
    return diagnostics;
}

Dictionary AeroSimNative::telemetry_snapshot() const {
    const aerosim::TelemetrySnapshot &snapshot = flight_controller_.telemetry_snapshot();
    Dictionary dict;
    dict["schema_version"] = snapshot.schema_version;
    dict["timestamp_us"] = static_cast<std::int64_t>(snapshot.timestamp_us);
    dict["publish_count"] = static_cast<std::int64_t>(snapshot.publish_count);
    dict["snapshot_hz"] = snapshot.snapshot_hz;
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
    Dictionary battery;
    battery["voltage_v"] = snapshot.battery.voltage_v;
    battery["sag_v"] = snapshot.battery.sag_v;
    battery["remaining_mah"] = snapshot.battery.remaining_mah;
    dict["battery"] = battery;
    Array pid;
    for (const aerosim::PidAxisTelemetry &axis : snapshot.pid) {
        pid.append(pid_telemetry_dict(axis));
    }
    dict["pid"] = pid;
    dict["armed"] = snapshot.armed;
    dict["mode"] = snapshot.mode.c_str();
    dict["source"] = "native_double_buffer";
    return dict;
}

bool AeroSimNative::set_a3_drag_model(
        bool enabled,
        double coefficient_x,
        double coefficient_y,
        double coefficient_z,
        double motor_0_rpm,
        double motor_1_rpm,
        double motor_2_rpm,
        double motor_3_rpm) {
    const double values[] = {
            coefficient_x,
            coefficient_y,
            coefficient_z,
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
    a3_drag_config_.enabled = enabled;
    a3_drag_config_.coefficient = {coefficient_x, coefficient_y, coefficient_z};
    a3_drag_config_.motor_rpm = {motor_0_rpm, motor_1_rpm, motor_2_rpm, motor_3_rpm};
    return true;
}

Dictionary AeroSimNative::a3_drag_configuration() const {
    Dictionary config;
    config["enabled"] = a3_drag_config_.enabled;
    config["coefficient_x"] = a3_drag_config_.coefficient.x;
    config["coefficient_y"] = a3_drag_config_.coefficient.y;
    config["coefficient_z"] = a3_drag_config_.coefficient.z;
    config["motor_0_rpm"] = a3_drag_config_.motor_rpm[0];
    config["motor_1_rpm"] = a3_drag_config_.motor_rpm[1];
    config["motor_2_rpm"] = a3_drag_config_.motor_rpm[2];
    config["motor_3_rpm"] = a3_drag_config_.motor_rpm[3];
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
    simulation_state_.position = {position_x, position_y, position_z};
    simulation_state_.orientation = {orientation_x, orientation_y, orientation_z, orientation_w};
    simulation_state_.velocity = {velocity_x, velocity_y, velocity_z};
    simulation_state_.angular_velocity = {angular_velocity_x, angular_velocity_y, angular_velocity_z};
}

PackedFloat64Array AeroSimNative::step_angle_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second) {
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    PackedFloat64Array row;
    const aerosim::ImuSample imu_sample = imu_.sample(simulation_state_);
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ANGLE";
    const aerosim::TrajectorySample sample = flight_controller_.step_angle_mode(
            simulation_state_,
            simulation_clock_,
            config,
            command,
            imu_sample.estimated_attitude);
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
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

    aerosim::AcroCommand command;
    command.throttle = throttle;
    command.roll_stick = roll_stick;
    command.pitch_stick = pitch_stick;
    command.yaw_stick = yaw_stick;
    command.rates = {rc_rate, super_rate, expo};

    const aerosim::TrajectorySample sample = flight_controller_.step_acro_mode(
            simulation_state_,
            simulation_clock_,
            config,
            command);
    flight_mode_ = "ACRO";

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
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

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

    const aerosim::ImuSample imu_sample = imu_.sample(simulation_state_);
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ANGLE";
    const aerosim::CollisionStepResult result = collision_authority_.step(
            simulation_state_,
            simulation_clock_,
            flight_controller_,
            config,
            command,
            contact,
            imu_sample.estimated_attitude);

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
    return row;
}

PackedFloat64Array AeroSimNative::step_altitude_hold_mode(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double throttle,
        double roll_degrees,
        double pitch_degrees,
        double yaw_rate_degrees_per_second) {
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    PackedFloat64Array row;
    const aerosim::ImuSample imu_sample = imu_.sample(simulation_state_);
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ALTITUDE_HOLD";
    const aerosim::TrajectorySample sample = flight_controller_.step_altitude_hold_mode(
            simulation_state_,
            simulation_clock_,
            config,
            command,
            imu_sample.barometer_altitude_m,
            imu_sample.estimated_attitude);
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
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

    PackedFloat64Array rows;
    for (const aerosim::TrajectorySample &sample : aerosim::simulate_trajectory(config)) {
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
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

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

    flight_mode_ = "ACRO";
    const aerosim::CollisionStepResult result = collision_authority_.step_acro(
            simulation_state_,
            simulation_clock_,
            flight_controller_,
            config,
            command,
            contact);

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
    aerosim::SimulationConfig config = hardware_config_.simulation_config();
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.a3_drag = a3_drag_config_;
    config.a4_ground_effect = a4_ground_effect_config_;

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

    const aerosim::ImuSample imu_sample = imu_.sample(simulation_state_);
    flight_control_used_estimated_attitude_ = true;
    flight_mode_ = "ALTITUDE_HOLD";
    const aerosim::CollisionStepResult result = collision_authority_.step_altitude_hold(
            simulation_state_,
            simulation_clock_,
            flight_controller_,
            config,
            command,
            imu_sample.barometer_altitude_m,
            contact,
            imu_sample.estimated_attitude);

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
    return row;
}
