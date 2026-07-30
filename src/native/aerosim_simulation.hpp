#pragma once

#include <cmath>
#include <cstdint>
#include <functional>
#include <array>
#include <string>
#include <vector>

namespace aerosim {

struct Vec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

struct Quat {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
    double w = 1.0;
};

struct RigidBodyState {
    Vec3 position;
    Vec3 velocity;
    Quat orientation;
    Vec3 angular_velocity;
    Vec3 propwash_disturbance_rad_s2;
    std::array<double, 4> motor_thrust_newtons = {0.0, 0.0, 0.0, 0.0};
    // PX4 HIL actuator outputs are requested rotor-speed ratios.  Keep their
    // lag state in the same physical domain rather than lagging thrust.
    std::array<double, 4> motor_rpm = {0.0, 0.0, 0.0, 0.0};
};

struct A3DragConfig {
    bool enabled = false;
    Vec3 coefficient;
};

struct A4GroundEffectConfig {
    bool enabled = false;
    double kf = 0.0;
    double ground_effect_coeff = 0.0;
    double prop_radius_m = 0.0;
    double height_clip_m = 0.0;
    std::array<double, 4> motor_rpm = {0.0, 0.0, 0.0, 0.0};
};

struct A5DownwashConfig {
    bool enabled = false;
    double prop_radius_m = 0.0;
    double coeff_1 = 0.0;
    double coeff_2 = 0.0;
    double coeff_3 = 0.0;
};

struct A6PropwashConfig {
    bool enabled = false;
    double full_collective_angular_accel_rad_s2 = 0.0;
    double minimum_wake_entry_speed_mps = 0.0;
    double minimum_transverse_rate_rad_s = 0.0;
};

struct BodyDragConfig {
    bool enabled = false;
    Vec3 drag_coefficient;
    Vec3 frontal_area_m2;
    Vec3 center_of_pressure_frd_m;
};

struct PerMotorPhysicsConfig {
    Vec3 inertia_kg_m2;
    std::array<Vec3, 4> position_frd{};
    std::array<double, 4> spin_direction = {0.0, 0.0, 0.0, 0.0};
    double max_thrust_per_motor_newtons = 0.0;
    double max_current_per_motor_a = 0.0;
    double yaw_torque_per_newton = 0.0;
};

bool validate_per_motor_config(const PerMotorPhysicsConfig &config);
std::array<std::array<double, 4>, 4> quad_x_mixer_columns(const PerMotorPhysicsConfig &config);

struct MotorCommands {
    std::array<double, 4> normalized = {0.0, 0.0, 0.0, 0.0};
};

struct Px4SupportLiftReadiness {
    bool valid = false;
    bool ready = false;
    double command_thrust_newtons = 0.0;
    double projected_lift_newtons = 0.0;
    double required_lift_newtons = 0.0;
    double thrust_scale = 0.0;
};

struct SimulationConfig {
    double seconds = 1.0;
    std::int32_t physics_hz = 240;
    std::int32_t substep_hz = 1000;
    double mass_kg = 1.0;
    double gravity_mps2 = 9.80665;
    double total_thrust_newtons = 0.0;
    double max_total_thrust_newtons = 0.0;
    double hover_throttle = 0.0;
    double motor_tau_s = 0.0;
    double battery_nominal_voltage_v = 0.0;
    double battery_cells = 0.0;
    double battery_cell_resistance_ohm = 0.0;
    double battery_remaining_mah = 0.0;
    double max_total_current_a = 0.0;
    double max_motor_rpm = 0.0;
    bool px4_actuator_rpm_mapping = false;
    double altitude_hold_noise_deadband_m = 0.0;
    PerMotorPhysicsConfig per_motor;
    A3DragConfig a3_drag;
    A4GroundEffectConfig a4_ground_effect;
    A5DownwashConfig a5_downwash;
    A6PropwashConfig a6_propwash;
    BodyDragConfig body_drag;
    double air_density_kg_m3 = 1.225;
    std::string config_hash = "unavailable";
    Vec3 external_force_world;
    std::function<Vec3(const Vec3 &)> external_force_provider;
    Vec3 wind_world_mps;
    Vec3 wind_turbulence_mps;
    RigidBodyState initial_state;
};

struct DualAircraftConfig {
    SimulationConfig upper;
    SimulationConfig lower;
};

struct DualAircraftState {
    RigidBodyState upper;
    RigidBodyState lower;
};

struct DualMotorCommands {
    MotorCommands upper;
    MotorCommands lower;
};

struct HardwareConfig {
    double mass_kg = 1.0;
    double max_total_thrust_newtons = 0.0;
    double hover_throttle = 0.0;
    double motor_tau_s = 0.0;
    double battery_nominal_voltage_v = 0.0;
    double battery_cells = 0.0;
    double battery_cell_resistance_ohm = 0.0;
    double battery_remaining_mah = 0.0;
    double max_total_current_a = 0.0;
    double max_motor_rpm = 0.0;
    double altitude_hold_noise_deadband_m = 0.0;
    A3DragConfig a3_drag;
    A6PropwashConfig a6_propwash;
    BodyDragConfig body_drag;
    double air_density_kg_m3 = 1.225;
    std::string config_hash = "unavailable";
    PerMotorPhysicsConfig per_motor;

    bool set_mass_kg(double value) {
        if (!std::isfinite(value) || value <= 0.0) {
            return false;
        }
        mass_kg = value;
        return true;
    }

    bool set_power_model(
            double max_thrust_newtons,
            double hover_throttle_value,
            double motor_tau_seconds,
            double battery_nominal_voltage,
            double battery_cell_count,
            double battery_cell_resistance,
            double max_current) {
        if (!std::isfinite(max_thrust_newtons) || max_thrust_newtons <= 0.0 ||
                !std::isfinite(hover_throttle_value) || hover_throttle_value <= 0.0 || hover_throttle_value > 1.0 ||
                !std::isfinite(motor_tau_seconds) || motor_tau_seconds < 0.0 ||
                !std::isfinite(battery_nominal_voltage) || battery_nominal_voltage <= 0.0 ||
                !std::isfinite(battery_cell_count) || battery_cell_count <= 0.0 ||
                !std::isfinite(battery_cell_resistance) || battery_cell_resistance < 0.0 ||
                !std::isfinite(max_current) || max_current <= 0.0) {
            return false;
        }
        max_total_thrust_newtons = max_thrust_newtons;
        hover_throttle = hover_throttle_value;
        motor_tau_s = motor_tau_seconds;
        battery_nominal_voltage_v = battery_nominal_voltage;
        battery_cells = battery_cell_count;
        battery_cell_resistance_ohm = battery_cell_resistance;
        max_total_current_a = max_current;
        return true;
    }

    bool set_telemetry_model(double max_motor_rpm_value, double battery_remaining_mah_value) {
        if (!std::isfinite(max_motor_rpm_value) || max_motor_rpm_value < 0.0 ||
                !std::isfinite(battery_remaining_mah_value) || battery_remaining_mah_value < 0.0) {
            return false;
        }
        max_motor_rpm = max_motor_rpm_value;
        battery_remaining_mah = battery_remaining_mah_value;
        return true;
    }

    bool set_altitude_hold_noise_deadband_m(double value) {
        if (!std::isfinite(value) || value < 0.0) {
            return false;
        }
        altitude_hold_noise_deadband_m = value;
        return true;
    }

    bool set_per_motor_model(const PerMotorPhysicsConfig &value) {
        if (!validate_per_motor_config(value)) {
            return false;
        }
        per_motor = value;
        return true;
    }

    bool set_a3_drag_model(bool enabled, const Vec3 &coefficient) {
        if (!std::isfinite(coefficient.x) || coefficient.x < 0.0 ||
                !std::isfinite(coefficient.y) || coefficient.y < 0.0 ||
                !std::isfinite(coefficient.z) || coefficient.z < 0.0) {
            return false;
        }
        a3_drag.enabled = enabled;
        a3_drag.coefficient = coefficient;
        return true;
    }

    bool set_a6_propwash_model(bool enabled, const A6PropwashConfig &value) {
        if (!std::isfinite(value.full_collective_angular_accel_rad_s2) ||
                value.full_collective_angular_accel_rad_s2 < 0.0 ||
                !std::isfinite(value.minimum_wake_entry_speed_mps) ||
                value.minimum_wake_entry_speed_mps < 0.0 ||
                !std::isfinite(value.minimum_transverse_rate_rad_s) ||
                value.minimum_transverse_rate_rad_s < 0.0) {
            return false;
        }
        a6_propwash = value;
        a6_propwash.enabled = enabled;
        return true;
    }

    bool set_body_drag_model(bool enabled, const BodyDragConfig &value, double density) {
        const double values[] = {
                value.drag_coefficient.x, value.drag_coefficient.y, value.drag_coefficient.z,
                value.frontal_area_m2.x, value.frontal_area_m2.y, value.frontal_area_m2.z,
                value.center_of_pressure_frd_m.x, value.center_of_pressure_frd_m.y,
                value.center_of_pressure_frd_m.z, density,
        };
        for (double number : values) {
            if (!std::isfinite(number)) {
                return false;
            }
        }
        if (value.drag_coefficient.x < 0.0 || value.drag_coefficient.y < 0.0 || value.drag_coefficient.z < 0.0 ||
                value.frontal_area_m2.x < 0.0 || value.frontal_area_m2.y < 0.0 || value.frontal_area_m2.z < 0.0 ||
                density <= 0.0) {
            return false;
        }
        body_drag = value;
        body_drag.enabled = enabled;
        air_density_kg_m3 = density;
        return true;
    }

    SimulationConfig simulation_config() const {
        SimulationConfig config;
        config.mass_kg = mass_kg;
        config.max_total_thrust_newtons = max_total_thrust_newtons;
        config.hover_throttle = hover_throttle;
        config.motor_tau_s = motor_tau_s;
        config.battery_nominal_voltage_v = battery_nominal_voltage_v;
        config.battery_cells = battery_cells;
        config.battery_cell_resistance_ohm = battery_cell_resistance_ohm;
        config.battery_remaining_mah = battery_remaining_mah;
        config.max_total_current_a = max_total_current_a;
        config.max_motor_rpm = max_motor_rpm;
        config.altitude_hold_noise_deadband_m = altitude_hold_noise_deadband_m;
        config.a3_drag = a3_drag;
        config.a6_propwash = a6_propwash;
        config.body_drag = body_drag;
        config.air_density_kg_m3 = air_density_kg_m3;
        config.config_hash = config_hash;
        config.per_motor = per_motor;
        return config;
    }
};

struct SimulationClock {
    double substep_accumulator = 0.0;
    std::uint64_t total_substeps = 0;
};

struct TrajectorySample {
    double time_seconds = 0.0;
    RigidBodyState state;
    std::uint64_t substeps = 0;
    Vec3 propwash_disturbance_rad_s2;
    Vec3 airspeed_body_frd_mps_mean;
    Vec3 body_drag_force_body_frd_n_mean;
    Vec3 body_drag_torque_body_frd_nm_mean;
    Vec3 a3_drag_force_body_frd_n_mean;
    double air_density_kg_m3 = 1.225;
    bool body_drag_force_applied = false;
    bool body_drag_torque_applied = false;
    RigidBodyState first_substep_state;
    double first_substep_time_seconds = 0.0;
    std::uint64_t first_substeps = 0;
};

struct DualAircraftTrajectorySample {
    double time_seconds = 0.0;
    DualAircraftState state;
    double downwash_force_y_newtons = 0.0;
    double minimum_downwash_force_y_newtons = 0.0;
    std::uint64_t substeps = 0;
};

double quat_norm(const Quat &q);
Vec3 frd_to_y_up(const Vec3 &frd);
Vec3 y_up_to_frd(const Vec3 &y_up);
double first_order_motor_response(double current, double target, double tau_s, double dt_s);
double available_thrust_cap_newtons(const SimulationConfig &config, double throttle);
Px4SupportLiftReadiness px4_support_lift_readiness(
        const SimulationConfig &config,
        const RigidBodyState &state,
        const MotorCommands &commands);
double motor_speed_rad_s_from_thrust(
        double thrust_newtons,
        double max_thrust_per_motor_newtons,
        double max_motor_rpm);
TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config);
TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const std::function<void(double)> &before_substep);
TrajectorySample step_per_motor_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const MotorCommands &commands);
TrajectorySample step_per_motor_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const std::function<MotorCommands(double)> &command_for_substep);
DualAircraftTrajectorySample step_dual_aircraft_per_motor_physics_frame(
        DualAircraftState &state,
        SimulationClock &clock,
        const DualAircraftConfig &config,
        const DualMotorCommands &commands);
DualAircraftTrajectorySample step_dual_aircraft_per_motor_physics_frame(
        DualAircraftState &state,
        SimulationClock &clock,
        const DualAircraftConfig &config,
        const std::function<DualMotorCommands(double)> &commands_for_substep);
std::vector<TrajectorySample> simulate_trajectory(const SimulationConfig &config);

} // namespace aerosim
