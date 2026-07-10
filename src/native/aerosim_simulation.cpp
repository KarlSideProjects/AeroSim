#include "aerosim_simulation.hpp"

#include "aerosim_aerodynamics.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace aerosim {
namespace {

Vec3 operator+(const Vec3 &a, const Vec3 &b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 operator*(const Vec3 &v, double scale) {
    return {v.x * scale, v.y * scale, v.z * scale};
}

Vec3 cross(const Vec3 &a, const Vec3 &b) {
    return {
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
    };
}

Quat normalized(const Quat &q) {
    const double norm = quat_norm(q);
    if (!std::isfinite(norm) || norm == 0.0) {
        return {};
    }
    return {q.x / norm, q.y / norm, q.z / norm, q.w / norm};
}

Quat multiply(const Quat &a, const Quat &b) {
    return {
            a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

Vec3 rotate(const Quat &q, const Vec3 &v) {
    const Quat vector{v.x, v.y, v.z, 0.0};
    const Quat inverse{-q.x, -q.y, -q.z, q.w};
    const Quat rotated = multiply(multiply(q, vector), inverse);
    return {rotated.x, rotated.y, rotated.z};
}

void integrate(RigidBodyState &state, const SimulationConfig &config, double dt) {
    const double ground_lift = a4_ground_effect_lift_newtons(config.a4_ground_effect, state.position.y);
    const Vec3 thrust_world = rotate(state.orientation, {0.0, config.total_thrust_newtons + ground_lift, 0.0});
    const Vec3 drag_world = rotate(state.orientation, a3_drag_force_body(config.a3_drag, state.orientation, state.velocity));
    const Vec3 force_world = thrust_world + drag_world;
    const Vec3 acceleration{
            force_world.x / config.mass_kg,
            force_world.y / config.mass_kg - config.gravity_mps2,
            force_world.z / config.mass_kg,
    };

    state.velocity = state.velocity + acceleration * dt;
    state.position = state.position + state.velocity * dt;

    const Quat omega{
            state.angular_velocity.x,
            state.angular_velocity.y,
            state.angular_velocity.z,
            0.0,
    };
    const Quat q_dot = multiply(state.orientation, omega);
    state.orientation = normalized({
            state.orientation.x + 0.5 * q_dot.x * dt,
            state.orientation.y + 0.5 * q_dot.y * dt,
            state.orientation.z + 0.5 * q_dot.z * dt,
            state.orientation.w + 0.5 * q_dot.w * dt,
    });
}

bool valid_per_motor_config(const PerMotorPhysicsConfig &config) {
    const double values[] = {
            config.inertia_kg_m2.x,
            config.inertia_kg_m2.y,
            config.inertia_kg_m2.z,
            config.max_thrust_per_motor_newtons,
            config.max_current_per_motor_a,
            config.yaw_torque_per_newton,
    };
    for (double value : values) {
        if (!std::isfinite(value) || value <= 0.0) {
            return false;
        }
    }
    for (std::size_t index = 0; index < config.position_frd.size(); ++index) {
        const Vec3 &position = config.position_frd[index];
        if (!std::isfinite(position.x) || !std::isfinite(position.y) || !std::isfinite(position.z) ||
                !std::isfinite(config.spin_direction[index]) ||
                (config.spin_direction[index] != -1.0 && config.spin_direction[index] != 1.0)) {
            return false;
        }
    }
    return true;
}

bool valid_motor_commands(const MotorCommands &commands) {
    for (double command : commands.normalized) {
        if (!std::isfinite(command) || command < 0.0 || command > 1.0) {
            return false;
        }
    }
    return true;
}

void integrate_per_motor(
        RigidBodyState &state,
        const SimulationConfig &config,
        const MotorCommands &commands,
        double dt) {
    const double average_command = std::accumulate(
            commands.normalized.begin(), commands.normalized.end(), 0.0) /
            static_cast<double>(commands.normalized.size());
    const double total_current = config.per_motor.max_current_per_motor_a *
            static_cast<double>(commands.normalized.size()) * average_command;
    double voltage_ratio = 1.0;
    if (config.battery_nominal_voltage_v > 0.0 && config.battery_cells > 0.0 &&
            config.battery_cell_resistance_ohm > 0.0) {
        const double loaded_voltage = config.battery_nominal_voltage_v -
                total_current * config.battery_cell_resistance_ohm * config.battery_cells;
        voltage_ratio = std::clamp(loaded_voltage / config.battery_nominal_voltage_v, 0.0, 1.0);
    }
    const double thrust_scale = voltage_ratio * voltage_ratio;

    Vec3 body_force;
    Vec3 body_torque;
    for (std::size_t index = 0; index < commands.normalized.size(); ++index) {
        const double target_thrust = config.per_motor.max_thrust_per_motor_newtons *
                commands.normalized[index] * thrust_scale;
        const double thrust = first_order_motor_response(
                state.motor_thrust_newtons[index], target_thrust, config.motor_tau_s, dt);
        state.motor_thrust_newtons[index] = thrust;
        const Vec3 force{0.0, thrust, 0.0};
        body_force = body_force + force;
        body_torque = body_torque + cross(frd_to_y_up(config.per_motor.position_frd[index]), force);
        body_torque.y -= config.per_motor.spin_direction[index] *
                config.per_motor.yaw_torque_per_newton * thrust;
    }

    const double ground_lift = a4_ground_effect_lift_newtons(config.a4_ground_effect, state.position.y);
    body_force.y += ground_lift;
    const Vec3 force_world = rotate(state.orientation, body_force) +
            rotate(state.orientation, a3_drag_force_body(config.a3_drag, state.orientation, state.velocity));
    const Vec3 acceleration{
            force_world.x / config.mass_kg,
            force_world.y / config.mass_kg - config.gravity_mps2,
            force_world.z / config.mass_kg,
    };
    state.velocity = state.velocity + acceleration * dt;
    state.position = state.position + state.velocity * dt;

    state.angular_velocity.x += body_torque.x / config.per_motor.inertia_kg_m2.x * dt;
    state.angular_velocity.y += body_torque.y / config.per_motor.inertia_kg_m2.y * dt;
    state.angular_velocity.z += body_torque.z / config.per_motor.inertia_kg_m2.z * dt;
    const Quat omega{state.angular_velocity.x, state.angular_velocity.y, state.angular_velocity.z, 0.0};
    const Quat q_dot = multiply(state.orientation, omega);
    state.orientation = normalized({
            state.orientation.x + 0.5 * q_dot.x * dt,
            state.orientation.y + 0.5 * q_dot.y * dt,
            state.orientation.z + 0.5 * q_dot.z * dt,
            state.orientation.w + 0.5 * q_dot.w * dt,
    });
}

} // namespace

double quat_norm(const Quat &q) {
    return std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
}

Vec3 frd_to_y_up(const Vec3 &frd) {
    return {frd.x, -frd.z, frd.y};
}

Vec3 y_up_to_frd(const Vec3 &y_up) {
    return {y_up.x, y_up.z, -y_up.y};
}

double first_order_motor_response(double current, double target, double tau_s, double dt_s) {
    if (!std::isfinite(current) || !std::isfinite(target) || !std::isfinite(tau_s) || !std::isfinite(dt_s) || dt_s < 0.0) {
        return current;
    }
    if (tau_s <= 0.0 || dt_s == 0.0) {
        return target;
    }
    const double alpha = 1.0 - std::exp(-dt_s / tau_s);
    return current + (target - current) * alpha;
}

double available_thrust_cap_newtons(const SimulationConfig &config, double throttle) {
    if (config.hover_throttle <= 0.0 || config.max_total_thrust_newtons <= 0.0) {
        return 0.0;
    }
    const double raw_cap = config.max_total_thrust_newtons;
    if (config.battery_nominal_voltage_v <= 0.0 ||
            config.battery_cells <= 0.0 ||
            config.battery_cell_resistance_ohm <= 0.0 ||
            config.max_total_current_a <= 0.0) {
        return raw_cap;
    }
    const double current_a = config.max_total_current_a * std::clamp(throttle, 0.0, 1.0);
    const double loaded_voltage = config.battery_nominal_voltage_v -
            current_a * config.battery_cell_resistance_ohm * config.battery_cells;
    const double voltage_ratio = std::clamp(loaded_voltage / config.battery_nominal_voltage_v, 0.0, 1.0);
    return raw_cap * voltage_ratio * voltage_ratio;
}

std::vector<TrajectorySample> simulate_trajectory(const SimulationConfig &config) {
    if (config.seconds <= 0.0 || config.physics_hz <= 0 || config.substep_hz <= 0 || config.mass_kg <= 0.0) {
        return {};
    }

    const auto physics_frames = static_cast<std::int32_t>(std::ceil(config.seconds * config.physics_hz));

    std::vector<TrajectorySample> samples;
    samples.reserve(static_cast<std::size_t>(physics_frames));

    RigidBodyState state = config.initial_state;
    SimulationClock clock;

    for (std::int32_t frame = 0; frame < physics_frames; ++frame) {
        samples.push_back(step_physics_frame(state, clock, config));
    }

    return samples;
}

TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config) {
    return step_physics_frame(state, clock, config, [](double) {});
}

TrajectorySample step_per_motor_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const MotorCommands &commands) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0 || config.mass_kg <= 0.0 ||
            !valid_per_motor_config(config.per_motor) || !valid_motor_commands(commands)) {
        return {};
    }

    const double substeps_per_frame = static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz);
    const double dt = 1.0 / static_cast<double>(config.substep_hz);
    clock.substep_accumulator += substeps_per_frame;
    const auto frame_substeps = static_cast<std::int32_t>(std::floor(clock.substep_accumulator + 1e-12));
    clock.substep_accumulator -= frame_substeps;
    for (std::int32_t step = 0; step < frame_substeps; ++step) {
        integrate_per_motor(state, config, commands, dt);
    }
    clock.total_substeps += static_cast<std::uint64_t>(frame_substeps);
    return {
            static_cast<double>(clock.total_substeps) * dt,
            state,
            clock.total_substeps,
    };
}

TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const std::function<void(double)> &before_substep) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0 || config.mass_kg <= 0.0) {
        return {};
    }

    const double substeps_per_frame = static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz);
    const double dt = 1.0 / static_cast<double>(config.substep_hz);

    clock.substep_accumulator += substeps_per_frame;
    const auto frame_substeps = static_cast<std::int32_t>(std::floor(clock.substep_accumulator + 1e-12));
    clock.substep_accumulator -= frame_substeps;

    for (std::int32_t step = 0; step < frame_substeps; ++step) {
        before_substep(dt);
        integrate(state, config, dt);
    }
    clock.total_substeps += static_cast<std::uint64_t>(frame_substeps);

    return {
            static_cast<double>(clock.total_substeps) * dt,
            state,
            clock.total_substeps,
    };
}

} // namespace aerosim
