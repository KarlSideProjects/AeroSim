#include "aerosim_simulation.hpp"

#include "aerosim_aerodynamics.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>

namespace aerosim {
namespace {

Vec3 operator+(const Vec3 &a, const Vec3 &b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 operator-(const Vec3 &a, const Vec3 &b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
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

bool valid_frame_timing(const SimulationConfig &config, const SimulationClock &clock) {
    constexpr double kMaxSubstepsPerFrame = 1000000.0;
    return config.physics_hz > 0 && config.substep_hz >= config.physics_hz &&
            static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz) <= kMaxSubstepsPerFrame &&
            std::isfinite(config.mass_kg) && config.mass_kg > 0.0 && std::isfinite(config.gravity_mps2) &&
            std::isfinite(clock.substep_accumulator) &&
            clock.substep_accumulator >= 0.0 && clock.substep_accumulator < 1.0;
}

bool finite_vec3(const Vec3 &value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

bool finite_state(const RigidBodyState &state) {
    return finite_vec3(state.position) && finite_vec3(state.velocity) &&
            std::isfinite(state.orientation.x) && std::isfinite(state.orientation.y) &&
            std::isfinite(state.orientation.z) && std::isfinite(state.orientation.w) &&
            finite_vec3(state.angular_velocity) && finite_vec3(state.propwash_disturbance_rad_s2) &&
            std::all_of(state.motor_thrust_newtons.begin(), state.motor_thrust_newtons.end(), [](double value) {
                return std::isfinite(value);
            });
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

Vec3 rotate_inverse(const Quat &q, const Vec3 &v) {
    const Quat vector{v.x, v.y, v.z, 0.0};
    const Quat inverse{-q.x, -q.y, -q.z, q.w};
    const Quat rotated = multiply(multiply(inverse, vector), q);
    return {rotated.x, rotated.y, rotated.z};
}

Vec3 frd_inertia_to_y_up_axes(const Vec3 &frd) {
    return {frd.x, frd.z, frd.y};
}

struct AerodynamicStepValues {
    Vec3 airspeed_body_frd_mps;
    Vec3 body_drag_force_body_frd_n;
    Vec3 body_drag_torque_body_frd_nm;
    Vec3 a3_drag_force_body_frd_n;
    double air_density_kg_m3 = 1.225;
    bool body_drag_force_applied = false;
    bool body_drag_torque_applied = false;
};

AerodynamicStepValues aerodynamic_values(
        const RigidBodyState &state,
        const SimulationConfig &config,
        const std::array<double, 4> &motor_speeds) {
    const Vec3 relative_air_velocity = state.velocity - config.wind_world_mps;
    const Vec3 airspeed_body_frd = y_up_to_frd(rotate_inverse(state.orientation, relative_air_velocity));
    const BodyDragWrench body_drag = body_drag_wrench_body_frd(
            config.body_drag,
            airspeed_body_frd,
            y_up_to_frd(state.angular_velocity),
            config.air_density_kg_m3);
    const bool body_drag_valid = config.body_drag.enabled &&
            validate_body_drag_config(config.body_drag, config.air_density_kg_m3);
    return {
            airspeed_body_frd,
            body_drag.force_body_frd_n,
            body_drag.torque_body_frd_nm,
            y_up_to_frd(a3_drag_force_body(
                    config.a3_drag, state.orientation, relative_air_velocity, motor_speeds)),
            config.air_density_kg_m3,
            body_drag_valid,
            body_drag_valid,
    };
}

AerodynamicStepValues add_aerodynamic_values(
        const AerodynamicStepValues &left,
        const AerodynamicStepValues &right) {
    return {
            left.airspeed_body_frd_mps + right.airspeed_body_frd_mps,
            left.body_drag_force_body_frd_n + right.body_drag_force_body_frd_n,
            left.body_drag_torque_body_frd_nm + right.body_drag_torque_body_frd_nm,
            left.a3_drag_force_body_frd_n + right.a3_drag_force_body_frd_n,
            right.air_density_kg_m3,
            left.body_drag_force_applied || right.body_drag_force_applied,
            left.body_drag_torque_applied || right.body_drag_torque_applied,
    };
}

AerodynamicStepValues integrate(RigidBodyState &state, const SimulationConfig &config, double dt) {
    const double ground_lift = a4_ground_effect_lift_newtons(config.a4_ground_effect, state.position.y);
    const Vec3 thrust_world = rotate(state.orientation, {0.0, config.total_thrust_newtons + ground_lift, 0.0});
    std::array<double, 4> motor_speeds{};
    for (std::size_t index = 0; index < motor_speeds.size(); ++index) {
        motor_speeds[index] = motor_speed_rad_s_from_thrust(
                state.motor_thrust_newtons[index],
                config.per_motor.max_thrust_per_motor_newtons,
                config.max_motor_rpm);
    }
    AerodynamicStepValues aero = aerodynamic_values(state, config, motor_speeds);
    const Vec3 drag_world = rotate(state.orientation, a3_drag_force_body(
            config.a3_drag, state.orientation, state.velocity - config.wind_world_mps, motor_speeds));
    const Vec3 body_drag_world = rotate(state.orientation, frd_to_y_up(aero.body_drag_force_body_frd_n));
    const Vec3 force_world = thrust_world + drag_world + body_drag_world;
    const Vec3 acceleration{
            force_world.x / config.mass_kg,
            force_world.y / config.mass_kg - config.gravity_mps2,
            force_world.z / config.mass_kg,
    };

    state.velocity = state.velocity + acceleration * dt;
    state.position = state.position + state.velocity * dt;

    if (aero.body_drag_torque_applied && validate_per_motor_config(config.per_motor)) {
        const Vec3 body_drag_torque_y_up = frd_to_y_up(aero.body_drag_torque_body_frd_nm);
        const Vec3 inertia_y_up = frd_inertia_to_y_up_axes(config.per_motor.inertia_kg_m2);
        state.angular_velocity.x += body_drag_torque_y_up.x / inertia_y_up.x * dt;
        state.angular_velocity.y += body_drag_torque_y_up.y / inertia_y_up.y * dt;
        state.angular_velocity.z += body_drag_torque_y_up.z / inertia_y_up.z * dt;
    } else {
        aero.body_drag_torque_applied = false;
    }

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
    return aero;
}

} // namespace

std::array<std::array<double, 4>, 4> quad_x_mixer_columns(const PerMotorPhysicsConfig &config) {
    std::array<std::array<double, 4>, 4> columns{};
    for (std::size_t index = 0; index < config.position_frd.size(); ++index) {
        columns[0][index] = 1.0;
        columns[1][index] = -config.position_frd[index].y;
        columns[2][index] = config.position_frd[index].x;
        columns[3][index] = config.spin_direction[index] * config.yaw_torque_per_newton;
    }
    return columns;
}

bool validate_per_motor_config(const PerMotorPhysicsConfig &config) {
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
    const double max_abs_position = std::max({
            std::abs(config.position_frd[0].x), std::abs(config.position_frd[0].y),
            std::abs(config.position_frd[1].x), std::abs(config.position_frd[1].y),
            std::abs(config.position_frd[2].x), std::abs(config.position_frd[2].y),
            std::abs(config.position_frd[3].x), std::abs(config.position_frd[3].y),
    });
    const double position_tolerance = 1e-9 * std::max(1.0, max_abs_position);
    const std::array<Vec3, 4> expected_quadrants = {{
            {-1.0, 1.0, 0.0}, {1.0, 1.0, 0.0},
            {-1.0, -1.0, 0.0}, {1.0, -1.0, 0.0},
    }};
    std::size_t positive_yaw_motors = 0;
    for (std::size_t index = 0; index < expected_quadrants.size(); ++index) {
        const Vec3 &actual = config.position_frd[index];
        const Vec3 &quadrant = expected_quadrants[index];
        if (std::abs(actual.z) > position_tolerance || std::abs(actual.x) <= position_tolerance ||
                std::abs(actual.y) <= position_tolerance || std::abs(actual.x) > 1.0 ||
                std::abs(actual.y) > 1.0 || actual.x * quadrant.x <= 0.0 ||
                actual.y * quadrant.y <= 0.0) {
            return false;
        }
        positive_yaw_motors += config.spin_direction[index] > 0.0 ? 1U : 0U;
        for (std::size_t other = 0; other < index; ++other) {
            const Vec3 &other_position = config.position_frd[other];
            if (std::abs(actual.x - other_position.x) <= position_tolerance &&
                    std::abs(actual.y - other_position.y) <= position_tolerance) {
                return false;
            }
        }
    }
    if (positive_yaw_motors != 2U) {
        return false;
    }

    const auto columns = quad_x_mixer_columns(config);
    std::array<double, 4> scales{};
    std::array<std::array<double, 4>, 4> normalized{};
    for (std::size_t axis = 0; axis < columns.size(); ++axis) {
        for (double coefficient : columns[axis]) {
            scales[axis] = std::max(scales[axis], std::abs(coefficient));
        }
        if (!std::isfinite(scales[axis]) || scales[axis] <= 0.0) {
            return false;
        }
        for (std::size_t index = 0; index < columns[axis].size(); ++index) {
            normalized[axis][index] = columns[axis][index] / scales[axis];
        }
    }
    // Iris is intentionally fore/aft asymmetric.  Require a full-rank allocation
    // matrix, not the former square-frame orthogonality shortcut.
    double determinant = 1.0;
    for (std::size_t pivot = 0; pivot < normalized.size(); ++pivot) {
        std::size_t best_row = pivot;
        for (std::size_t row = pivot + 1; row < normalized.size(); ++row) {
            if (std::abs(normalized[row][pivot]) > std::abs(normalized[best_row][pivot])) {
                best_row = row;
            }
        }
        if (std::abs(normalized[best_row][pivot]) <= 1e-9) {
            return false;
        }
        if (best_row != pivot) {
            std::swap(normalized[best_row], normalized[pivot]);
            determinant = -determinant;
        }
        const double pivot_value = normalized[pivot][pivot];
        determinant *= pivot_value;
        for (std::size_t row = pivot + 1; row < normalized.size(); ++row) {
            const double factor = normalized[row][pivot] / pivot_value;
            for (std::size_t column = pivot; column < normalized[row].size(); ++column) {
                normalized[row][column] -= factor * normalized[pivot][column];
            }
        }
    }
    if (!std::isfinite(determinant) || std::abs(determinant) <= 1e-9) {
        return false;
    }
    return true;
}

namespace {

bool valid_motor_commands(const MotorCommands &commands) {
    for (double command : commands.normalized) {
        if (!std::isfinite(command) || command < 0.0 || command > 1.0) {
            return false;
        }
    }
    return true;
}

double per_motor_thrust_scale(const SimulationConfig &config, const MotorCommands &commands) {
    const double average_command = std::accumulate(
            commands.normalized.begin(), commands.normalized.end(), 0.0) /
            static_cast<double>(commands.normalized.size());
    if (config.battery_nominal_voltage_v <= 0.0 || config.battery_cells <= 0.0 ||
            config.battery_cell_resistance_ohm <= 0.0) {
        return 1.0;
    }
    const double total_current = config.per_motor.max_current_per_motor_a *
            static_cast<double>(commands.normalized.size()) * average_command;
    const double loaded_voltage = config.battery_nominal_voltage_v -
            total_current * config.battery_cell_resistance_ohm * config.battery_cells;
    const double voltage_ratio = std::clamp(loaded_voltage / config.battery_nominal_voltage_v, 0.0, 1.0);
    return voltage_ratio * voltage_ratio;
}

AerodynamicStepValues integrate_per_motor(
        RigidBodyState &state,
        const SimulationConfig &config,
        const MotorCommands &commands,
        const Vec3 &external_force_world,
        double dt) {
    const double thrust_scale = per_motor_thrust_scale(config, commands);

    Vec3 body_force;
    Vec3 body_torque;
    Vec3 motor_torque_frd;
    const auto columns = quad_x_mixer_columns(config.per_motor);
    for (std::size_t index = 0; index < commands.normalized.size(); ++index) {
        const double target_thrust = config.per_motor.max_thrust_per_motor_newtons *
                commands.normalized[index] * thrust_scale;
        const double thrust = first_order_motor_response(
                state.motor_thrust_newtons[index], target_thrust, config.motor_tau_s, dt);
        state.motor_thrust_newtons[index] = thrust;
        const Vec3 force{0.0, thrust, 0.0};
        body_force = body_force + force;
        motor_torque_frd.x += columns[1][index] * thrust;
        motor_torque_frd.y += columns[2][index] * thrust;
        motor_torque_frd.z += columns[3][index] * thrust;
    }

    body_torque = body_torque + frd_to_y_up(motor_torque_frd);

    const double ground_lift = a4_ground_effect_lift_newtons(config.a4_ground_effect, state.position.y);
    body_force.y += ground_lift;
    std::array<double, 4> motor_speeds{};
    for (std::size_t index = 0; index < motor_speeds.size(); ++index) {
        motor_speeds[index] = motor_speed_rad_s_from_thrust(
                state.motor_thrust_newtons[index],
                config.per_motor.max_thrust_per_motor_newtons,
                config.max_motor_rpm);
    }
    const AerodynamicStepValues aero = aerodynamic_values(state, config, motor_speeds);
    body_force = body_force + frd_to_y_up(aero.body_drag_force_body_frd_n);
    body_torque = body_torque + frd_to_y_up(aero.body_drag_torque_body_frd_nm);
    const Vec3 configured_external_force = config.external_force_world +
            (config.external_force_provider ? config.external_force_provider(state.position) : Vec3{});
    const Vec3 force_world = rotate(state.orientation, body_force) + external_force_world + configured_external_force +
            rotate(state.orientation, a3_drag_force_body(
                    config.a3_drag, state.orientation, state.velocity - config.wind_world_mps, motor_speeds));
    const Vec3 acceleration{
            force_world.x / config.mass_kg,
            force_world.y / config.mass_kg - config.gravity_mps2,
            force_world.z / config.mass_kg,
    };
    state.velocity = state.velocity + acceleration * dt;
    state.position = state.position + state.velocity * dt;

    const Vec3 inertia_y_up = frd_inertia_to_y_up_axes(config.per_motor.inertia_kg_m2);
    state.angular_velocity.x += body_torque.x / inertia_y_up.x * dt;
    state.angular_velocity.y += body_torque.y / inertia_y_up.y * dt;
    state.angular_velocity.z += body_torque.z / inertia_y_up.z * dt;
    double collective = 0.0;
    if (config.per_motor.max_thrust_per_motor_newtons > 0.0) {
        for (double thrust : state.motor_thrust_newtons) {
            collective += std::clamp(
                    thrust / config.per_motor.max_thrust_per_motor_newtons,
                    0.0,
                    1.0);
        }
        collective /= static_cast<double>(state.motor_thrust_newtons.size());
    }
    state.propwash_disturbance_rad_s2 = a6_propwash_angular_acceleration_rad_s2(
            config.a6_propwash,
            state,
            state.velocity - config.wind_world_mps,
            collective);
    state.angular_velocity = state.angular_velocity + state.propwash_disturbance_rad_s2 * dt;
    const Quat omega{state.angular_velocity.x, state.angular_velocity.y, state.angular_velocity.z, 0.0};
    const Quat q_dot = multiply(state.orientation, omega);
    state.orientation = normalized({
            state.orientation.x + 0.5 * q_dot.x * dt,
            state.orientation.y + 0.5 * q_dot.y * dt,
            state.orientation.z + 0.5 * q_dot.z * dt,
            state.orientation.w + 0.5 * q_dot.w * dt,
    });
    return aero;
}

} // namespace

double quat_norm(const Quat &q) {
    return std::hypot(std::hypot(q.x, q.y), std::hypot(q.z, q.w));
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

Px4SupportLiftReadiness px4_support_lift_readiness(
        const SimulationConfig &config,
        const RigidBodyState &state,
        const MotorCommands &commands) {
    Px4SupportLiftReadiness readiness;
    if (!std::isfinite(config.mass_kg) || config.mass_kg <= 0.0 ||
            !std::isfinite(config.gravity_mps2) || config.gravity_mps2 < 0.0 ||
            !validate_per_motor_config(config.per_motor) || !valid_motor_commands(commands) ||
            !std::isfinite(state.orientation.x) || !std::isfinite(state.orientation.y) ||
            !std::isfinite(state.orientation.z) || !std::isfinite(state.orientation.w) ||
            quat_norm(state.orientation) <= 0.0) {
        return readiness;
    }
    readiness.thrust_scale = per_motor_thrust_scale(config, commands);
    for (double command : commands.normalized) {
        readiness.command_thrust_newtons += config.per_motor.max_thrust_per_motor_newtons * command * readiness.thrust_scale;
    }
    readiness.projected_lift_newtons = rotate(
            state.orientation, {0.0, readiness.command_thrust_newtons, 0.0}).y;
    readiness.required_lift_newtons = config.mass_kg * config.gravity_mps2;
    readiness.valid = std::isfinite(readiness.thrust_scale) &&
            std::isfinite(readiness.command_thrust_newtons) &&
            std::isfinite(readiness.projected_lift_newtons) &&
            std::isfinite(readiness.required_lift_newtons);
    readiness.ready = readiness.valid && readiness.projected_lift_newtons > readiness.required_lift_newtons;
    return readiness;
}

double motor_speed_rad_s_from_thrust(
        double thrust_newtons,
        double max_thrust_per_motor_newtons,
        double max_motor_rpm) {
    if (!std::isfinite(thrust_newtons) || thrust_newtons < 0.0 ||
            !std::isfinite(max_thrust_per_motor_newtons) || max_thrust_per_motor_newtons <= 0.0 ||
            !std::isfinite(max_motor_rpm) || max_motor_rpm <= 0.0) {
        return 0.0;
    }
    constexpr double kRadiansPerSecondPerRpm = 2.0 * 3.14159265358979323846 / 60.0;
    const double motor_rpm = max_motor_rpm *
            std::sqrt(std::clamp(thrust_newtons / max_thrust_per_motor_newtons, 0.0, 1.0));
    return motor_rpm * kRadiansPerSecondPerRpm;
}

std::vector<TrajectorySample> simulate_trajectory(const SimulationConfig &config) {
    if (!std::isfinite(config.seconds) || config.seconds <= 0.0 || config.physics_hz <= 0 ||
            config.substep_hz <= 0 || !std::isfinite(config.mass_kg) || config.mass_kg <= 0.0 ||
            !std::isfinite(config.gravity_mps2)) {
        return {};
    }
    constexpr std::size_t kMaxTrajectoryFrames = 1000000;
    const double frames_as_double = std::ceil(config.seconds * static_cast<double>(config.physics_hz));
    if (!std::isfinite(frames_as_double) || frames_as_double <= 0.0 ||
            frames_as_double > static_cast<double>(kMaxTrajectoryFrames) ||
            frames_as_double * static_cast<double>(config.substep_hz) /
                    static_cast<double>(config.physics_hz) > static_cast<double>(kMaxTrajectoryFrames)) {
        return {};
    }
    const std::size_t physics_frames = static_cast<std::size_t>(frames_as_double);

    std::vector<TrajectorySample> samples;
    samples.reserve(static_cast<std::size_t>(physics_frames));

    RigidBodyState state = config.initial_state;
    SimulationClock clock;

    for (std::size_t frame = 0; frame < physics_frames; ++frame) {
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
    return step_per_motor_physics_frame(
            state,
            clock,
            config,
            [&commands](double) { return commands; });
}

TrajectorySample step_per_motor_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const std::function<MotorCommands(double)> &command_for_substep) {
    if (!valid_frame_timing(config, clock) ||
            !validate_per_motor_config(config.per_motor) || !command_for_substep) {
        return {};
    }

    const RigidBodyState initial_state = state;
    const SimulationClock initial_clock = clock;
    Vec3 propwash_sum;
    AerodynamicStepValues aerodynamic_sum;
    RigidBodyState first_substep_state;
    bool has_first_substep = false;
    const double substeps_per_frame = static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz);
    const double dt = 1.0 / static_cast<double>(config.substep_hz);
    const double next_accumulator = clock.substep_accumulator + substeps_per_frame;
    const auto frame_substeps = static_cast<std::uint64_t>(std::floor(next_accumulator + 1e-12));
    if (frame_substeps > std::numeric_limits<std::uint64_t>::max() - clock.total_substeps) {
        return {};
    }
    clock.substep_accumulator = next_accumulator - static_cast<double>(frame_substeps);
    for (std::uint64_t step = 0; step < frame_substeps; ++step) {
        const MotorCommands commands = command_for_substep(dt);
        if (!valid_motor_commands(commands)) {
            state = initial_state;
            clock = initial_clock;
            return {};
        }
        const AerodynamicStepValues aerodynamic = integrate_per_motor(state, config, commands, {}, dt);
        if (!finite_state(state)) {
            state = initial_state;
            clock = initial_clock;
            return {};
        }
        if (!has_first_substep) {
            first_substep_state = state;
            has_first_substep = true;
        }
        aerodynamic_sum = add_aerodynamic_values(aerodynamic_sum, aerodynamic);
        propwash_sum = propwash_sum + state.propwash_disturbance_rad_s2;
    }
    clock.total_substeps += static_cast<std::uint64_t>(frame_substeps);
    const Vec3 propwash_average = frame_substeps > 0
            ? propwash_sum * (1.0 / static_cast<double>(frame_substeps))
            : Vec3{};
    const double mean_scale = frame_substeps > 0 ? 1.0 / static_cast<double>(frame_substeps) : 0.0;
    return {
            static_cast<double>(clock.total_substeps) * dt,
            state,
            clock.total_substeps,
            propwash_average,
            aerodynamic_sum.airspeed_body_frd_mps * mean_scale,
            aerodynamic_sum.body_drag_force_body_frd_n * mean_scale,
            aerodynamic_sum.body_drag_torque_body_frd_nm * mean_scale,
            aerodynamic_sum.a3_drag_force_body_frd_n * mean_scale,
            config.air_density_kg_m3,
            aerodynamic_sum.body_drag_force_applied,
            aerodynamic_sum.body_drag_torque_applied,
            first_substep_state,
            has_first_substep ? static_cast<double>(initial_clock.total_substeps + 1U) * dt : 0.0,
            has_first_substep ? initial_clock.total_substeps + 1U : 0U,
    };
}

DualAircraftTrajectorySample step_dual_aircraft_per_motor_physics_frame(
        DualAircraftState &state,
        SimulationClock &clock,
        const DualAircraftConfig &config,
        const DualMotorCommands &commands) {
    return step_dual_aircraft_per_motor_physics_frame(
            state,
            clock,
            config,
            [&commands](double) { return commands; });
}

DualAircraftTrajectorySample step_dual_aircraft_per_motor_physics_frame(
        DualAircraftState &state,
        SimulationClock &clock,
        const DualAircraftConfig &config,
        const std::function<DualMotorCommands(double)> &commands_for_substep) {
    if (!valid_frame_timing(config.upper, clock) ||
            config.lower.physics_hz != config.upper.physics_hz ||
            config.lower.substep_hz != config.upper.substep_hz ||
            !std::isfinite(config.lower.mass_kg) || config.lower.mass_kg <= 0.0 ||
            !std::isfinite(config.lower.gravity_mps2) ||
            !validate_per_motor_config(config.upper.per_motor) ||
            !validate_per_motor_config(config.lower.per_motor) || !commands_for_substep) {
        return {};
    }

    const DualAircraftState initial_state = state;
    const SimulationClock initial_clock = clock;
    const double substeps_per_frame = static_cast<double>(config.upper.substep_hz) /
            static_cast<double>(config.upper.physics_hz);
    const double dt = 1.0 / static_cast<double>(config.upper.substep_hz);
    clock.substep_accumulator += substeps_per_frame;
    const auto frame_substeps = static_cast<std::int32_t>(std::floor(clock.substep_accumulator + 1e-12));
    clock.substep_accumulator -= frame_substeps;
    double downwash_force_y_newtons = 0.0;
    double minimum_downwash_force_y_newtons = 0.0;
    for (std::int32_t step = 0; step < frame_substeps; ++step) {
        const DualMotorCommands commands = commands_for_substep(dt);
        if (!valid_motor_commands(commands.upper) || !valid_motor_commands(commands.lower)) {
            state = initial_state;
            clock = initial_clock;
            return {};
        }
        downwash_force_y_newtons = a5_downwash_force_y_newtons(
                config.upper.a5_downwash,
                state.upper.position,
                state.lower.position);
        minimum_downwash_force_y_newtons = std::min(
                minimum_downwash_force_y_newtons,
                downwash_force_y_newtons);
        integrate_per_motor(state.upper, config.upper, commands.upper, {}, dt);
        integrate_per_motor(
                state.lower,
                config.lower,
                commands.lower,
                {0.0, downwash_force_y_newtons, 0.0},
                dt);
        if (!finite_state(state.upper) || !finite_state(state.lower)) {
            state = initial_state;
            clock = initial_clock;
            return {};
        }
    }
    clock.total_substeps += static_cast<std::uint64_t>(frame_substeps);
    return {
            static_cast<double>(clock.total_substeps) * dt,
            state,
            downwash_force_y_newtons,
            minimum_downwash_force_y_newtons,
            clock.total_substeps,
    };
}

TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const std::function<void(double)> &before_substep) {
    if (!valid_frame_timing(config, clock) || !before_substep) {
        return {};
    }

    const RigidBodyState initial_state = state;
    const SimulationClock initial_clock = clock;

    const double substeps_per_frame = static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz);
    const double dt = 1.0 / static_cast<double>(config.substep_hz);

    clock.substep_accumulator += substeps_per_frame;
    const auto frame_substeps = static_cast<std::int32_t>(std::floor(clock.substep_accumulator + 1e-12));
    clock.substep_accumulator -= frame_substeps;

    AerodynamicStepValues aerodynamic_sum;
    for (std::int32_t step = 0; step < frame_substeps; ++step) {
        before_substep(dt);
        aerodynamic_sum = add_aerodynamic_values(aerodynamic_sum, integrate(state, config, dt));
        if (!finite_state(state)) {
            state = initial_state;
            clock = initial_clock;
            return {};
        }
    }
    clock.total_substeps += static_cast<std::uint64_t>(frame_substeps);

    const double mean_scale = frame_substeps > 0 ? 1.0 / static_cast<double>(frame_substeps) : 0.0;
    return {
            static_cast<double>(clock.total_substeps) * dt,
            state,
            clock.total_substeps,
            {},
            aerodynamic_sum.airspeed_body_frd_mps * mean_scale,
            aerodynamic_sum.body_drag_force_body_frd_n * mean_scale,
            aerodynamic_sum.body_drag_torque_body_frd_nm * mean_scale,
            aerodynamic_sum.a3_drag_force_body_frd_n * mean_scale,
            config.air_density_kg_m3,
            aerodynamic_sum.body_drag_force_applied,
            aerodynamic_sum.body_drag_torque_applied,
            {},
            0.0,
            0,
    };
}

} // namespace aerosim
