#include "aerosim_simulation.hpp"

#include <algorithm>
#include <cmath>

namespace aerosim {
namespace {

Vec3 operator+(const Vec3 &a, const Vec3 &b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 operator*(const Vec3 &v, double scale) {
    return {v.x * scale, v.y * scale, v.z * scale};
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
    const Vec3 thrust_world = rotate(state.orientation, {0.0, config.total_thrust_newtons, 0.0});
    const Vec3 acceleration{
            thrust_world.x / config.mass_kg,
            thrust_world.y / config.mass_kg - config.gravity_mps2,
            thrust_world.z / config.mass_kg,
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

} // namespace

double quat_norm(const Quat &q) {
    return std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
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
    if (config.physics_hz <= 0 || config.substep_hz <= 0 || config.mass_kg <= 0.0) {
        return {};
    }

    const double substeps_per_frame = static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz);
    const double dt = 1.0 / static_cast<double>(config.substep_hz);

    clock.substep_accumulator += substeps_per_frame;
    const auto frame_substeps = static_cast<std::int32_t>(std::floor(clock.substep_accumulator + 1e-12));
    clock.substep_accumulator -= frame_substeps;

    for (std::int32_t step = 0; step < frame_substeps; ++step) {
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
