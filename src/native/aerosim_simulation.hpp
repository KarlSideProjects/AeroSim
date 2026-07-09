#pragma once

#include <cmath>
#include <cstdint>
#include <functional>
#include <array>
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
};

struct A3DragConfig {
    bool enabled = false;
    Vec3 coefficient;
    std::array<double, 4> motor_rpm = {0.0, 0.0, 0.0, 0.0};
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
    double max_total_current_a = 0.0;
    A3DragConfig a3_drag;
    RigidBodyState initial_state;
};

struct HardwareConfig {
    double mass_kg = 1.0;
    double max_total_thrust_newtons = 0.0;
    double hover_throttle = 0.0;
    double motor_tau_s = 0.0;
    double battery_nominal_voltage_v = 0.0;
    double battery_cells = 0.0;
    double battery_cell_resistance_ohm = 0.0;
    double max_total_current_a = 0.0;

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

    SimulationConfig simulation_config() const {
        SimulationConfig config;
        config.mass_kg = mass_kg;
        config.max_total_thrust_newtons = max_total_thrust_newtons;
        config.hover_throttle = hover_throttle;
        config.motor_tau_s = motor_tau_s;
        config.battery_nominal_voltage_v = battery_nominal_voltage_v;
        config.battery_cells = battery_cells;
        config.battery_cell_resistance_ohm = battery_cell_resistance_ohm;
        config.max_total_current_a = max_total_current_a;
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
};

double quat_norm(const Quat &q);
double first_order_motor_response(double current, double target, double tau_s, double dt_s);
double available_thrust_cap_newtons(const SimulationConfig &config, double throttle);
TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config);
TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const std::function<void(double)> &before_substep);
std::vector<TrajectorySample> simulate_trajectory(const SimulationConfig &config);

} // namespace aerosim
