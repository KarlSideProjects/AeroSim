#include "aerosim_native.hpp"

#include "aerosim_probe.hpp"
#include <godot_cpp/core/class_db.hpp>
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

Vector3 godot_vec3(const aerosim::Vec3 &value) {
    return {static_cast<real_t>(value.x), static_cast<real_t>(value.y), static_cast<real_t>(value.z)};
}

} // namespace

void AeroSimNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("probe_value"), &AeroSimNative::probe_value);
    ClassDB::bind_method(D_METHOD("trajectory_stride"), &AeroSimNative::trajectory_stride);
    ClassDB::bind_method(D_METHOD("set_hardware_mass_kg", "mass_kg"), &AeroSimNative::set_hardware_mass_kg);
    ClassDB::bind_method(
            D_METHOD("set_hardware_power_model", "max_total_thrust_newtons", "hover_throttle", "motor_tau_s", "battery_nominal_voltage_v", "battery_cells", "battery_cell_resistance_ohm", "max_total_current_a"),
            &AeroSimNative::set_hardware_power_model);
    ClassDB::bind_method(D_METHOD("reset_simulation"), &AeroSimNative::reset_simulation);
    ClassDB::bind_method(
            D_METHOD("step_simulation", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::step_simulation);
    ClassDB::bind_method(D_METHOD("arm_flight_control", "throttle"), &AeroSimNative::arm_flight_control);
    ClassDB::bind_method(D_METHOD("flight_control_armed"), &AeroSimNative::flight_control_armed);
    ClassDB::bind_method(D_METHOD("flight_control_arm_reject_code"), &AeroSimNative::flight_control_arm_reject_code);
    ClassDB::bind_method(D_METHOD("reset_flight"), &AeroSimNative::reset_flight);
    ClassDB::bind_method(D_METHOD("configure_imu", "config"), &AeroSimNative::configure_imu);
    ClassDB::bind_method(D_METHOD("imu_configuration"), &AeroSimNative::imu_configuration);
    ClassDB::bind_method(D_METHOD("flight_control_diagnostics"), &AeroSimNative::flight_control_diagnostics);
    ClassDB::bind_method(D_METHOD("hardware_power_diagnostics"), &AeroSimNative::hardware_power_diagnostics);
    ClassDB::bind_method(D_METHOD("set_collision_release_frames", "release_frames"), &AeroSimNative::set_collision_release_frames);
    ClassDB::bind_method(
            D_METHOD("sync_flight_state", "position_x", "position_y", "position_z", "orientation_x", "orientation_y", "orientation_z", "orientation_w", "velocity_x", "velocity_y", "velocity_z", "angular_velocity_x", "angular_velocity_y", "angular_velocity_z"),
            &AeroSimNative::sync_flight_state);
    ClassDB::bind_method(
            D_METHOD("step_angle_mode", "physics_hz", "substep_hz", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second"),
            &AeroSimNative::step_angle_mode);
    ClassDB::bind_method(
            D_METHOD("step_collision_angle_mode", "physics_hz", "substep_hz", "throttle", "roll_degrees", "pitch_degrees", "yaw_rate_degrees_per_second", "touching", "normal_x", "normal_y", "normal_z", "impulse_x", "impulse_y", "impulse_z", "restitution", "resolved_velocity_x", "resolved_velocity_y", "resolved_velocity_z", "resolved_angular_velocity_x", "resolved_angular_velocity_y", "resolved_angular_velocity_z", "max_kinetic_energy_joules"),
            &AeroSimNative::step_collision_angle_mode);
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
    return diagnostics;
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

    aerosim::FlightCommand command;
    command.throttle = throttle;
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    command.yaw_rate_degrees_per_second = yaw_rate_degrees_per_second;

    PackedFloat64Array row;
    const aerosim::ImuSample imu_sample = imu_.sample(simulation_state_);
    flight_control_used_estimated_attitude_ = true;
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
