#include "aerosim_flight_control.hpp"

#include "aerosim_aerodynamics.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

Quat multiply(const Quat &a, const Quat &b) {
    return {
            a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

Vec3 world_to_body(const Quat &attitude, const Vec3 &world) {
    const Quat vector{world.x, world.y, world.z, 0.0};
    const Quat conjugate{-attitude.x, -attitude.y, -attitude.z, attitude.w};
    const Quat rotated = multiply(multiply(conjugate, vector), attitude);
    return {rotated.x, rotated.y, rotated.z};
}
constexpr double kAngleP = 20.0;
constexpr double kRateP = 0.600;
constexpr double kRateI = 0.020;
constexpr double kMaxRateRadS = 16.0;
constexpr double kTargetRateAccelerationRadS2 = 80.0;
constexpr double kRateIntegralLimitNm = 0.20;
constexpr double kAltitudeHoldEstimateTauS = 2.0;
constexpr double kAltitudeHoldKp = 0.08;
constexpr double kAltitudeHoldKd = 0.20;
constexpr double kAltitudeHoldNoiseDeadbandM = 0.15;

double radians(double degrees) {
    return degrees * kPi / 180.0;
}

double angle_x(const Quat &q) {
    return 2.0 * std::atan2(q.x, q.w);
}

double angle_z(const Quat &q) {
    return 2.0 * std::atan2(q.z, q.w);
}

double power3(double value) {
    return value * value * value;
}

double alpha_from_tau(double dt, double tau) {
    if (dt <= 0.0 || tau <= 0.0) {
        return 1.0;
    }
    return std::clamp(dt / (tau + dt), 0.0, 1.0);
}

double target_thrust_newtons(const SimulationConfig &config, double throttle) {
    if (config.hover_throttle <= 0.0) {
        return 0.0;
    }
    const double uncapped = config.mass_kg * config.gravity_mps2 * throttle / config.hover_throttle;
    return std::clamp(uncapped, 0.0, available_thrust_cap_newtons(config, throttle));
}

double loaded_voltage_v(const SimulationConfig &config, double throttle) {
    if (config.battery_nominal_voltage_v <= 0.0) {
        return 0.0;
    }
    if (config.battery_cells <= 0.0 ||
            config.battery_cell_resistance_ohm <= 0.0 ||
            config.max_total_current_a <= 0.0) {
        return config.battery_nominal_voltage_v;
    }
    const double current_a = config.max_total_current_a * std::clamp(throttle, 0.0, 1.0);
    return std::max(
            0.0,
            config.battery_nominal_voltage_v -
                    current_a * config.battery_cell_resistance_ohm * config.battery_cells);
}

double shaped_rate(double desired, double previous, double dt) {
    const double limited_desired = std::clamp(desired, -kMaxRateRadS, kMaxRateRadS);
    const double maximum_delta = kTargetRateAccelerationRadS2 * std::max(dt, 0.0);
    return std::clamp(limited_desired, previous - maximum_delta, previous + maximum_delta);
}

} // namespace

QuadXMixerResult quad_x_mix_thrust(
        const SimulationConfig &config,
        double collective_thrust_newtons,
        const Vec3 &target_torque_frd_nm) {
    QuadXMixerResult result;
    if (!validate_per_motor_config(config.per_motor) ||
            !std::isfinite(collective_thrust_newtons) || collective_thrust_newtons < 0.0 ||
            !std::isfinite(target_torque_frd_nm.x) ||
            !std::isfinite(target_torque_frd_nm.y) ||
            !std::isfinite(target_torque_frd_nm.z)) {
        return result;
    }

    const auto &per_motor = config.per_motor;
    const auto columns = quad_x_mixer_columns(config.per_motor);
    const std::array<double, 4> targets = {
            collective_thrust_newtons,
            target_torque_frd_nm.x,
            target_torque_frd_nm.y,
            target_torque_frd_nm.z,
    };
    std::array<double, 4> delta_thrust{};
    for (std::size_t axis = 1; axis < columns.size(); ++axis) {
        double denominator = 0.0;
        for (double coefficient : columns[axis]) {
            denominator += coefficient * coefficient;
        }
        if (!std::isfinite(denominator) || denominator <= 0.0) {
            return result;
        }
        for (std::size_t index = 0; index < delta_thrust.size(); ++index) {
            delta_thrust[index] += columns[axis][index] * targets[axis] / denominator;
        }
    }

    const double max_thrust = per_motor.max_thrust_per_motor_newtons;
    const double requested_base = collective_thrust_newtons / 4.0;
    double minimum_delta = delta_thrust[0];
    double maximum_delta = delta_thrust[0];
    for (double delta : delta_thrust) {
        minimum_delta = std::min(minimum_delta, delta);
        maximum_delta = std::max(maximum_delta, delta);
    }
    const double delta_range = maximum_delta - minimum_delta;
    double axis_scale = 1.0;
    if (delta_range > max_thrust) {
        axis_scale = (max_thrust * (1.0 - 1.0e-12)) / delta_range;
        result.axis_saturated = {true, true, true};
        for (double &delta : delta_thrust) {
            delta *= axis_scale;
        }
        minimum_delta *= axis_scale;
        maximum_delta *= axis_scale;
    }

    const double minimum_base = -minimum_delta;
    const double maximum_base = max_thrust - maximum_delta;
    const double base = std::clamp(requested_base, minimum_base, maximum_base);
    result.collective_saturated = std::abs(base - requested_base) > 1e-12;
    for (std::size_t index = 0; index < result.normalized.size(); ++index) {
        const double thrust = base + delta_thrust[index];
        if (!std::isfinite(thrust) || thrust < -1e-9 || thrust > max_thrust + 1e-9) {
            return QuadXMixerResult{};
        }
        result.normalized[index] = std::clamp(thrust / max_thrust, 0.0, 1.0);
    }
    result.valid = true;
    return result;
}

double betaflight_rate_degrees_per_second(double stick, const RateProfile &profile) {
    if (!std::isfinite(stick) ||
            !std::isfinite(profile.rc_rate) ||
            !std::isfinite(profile.super_rate) ||
            !std::isfinite(profile.expo)) {
        return 0.0;
    }
    const double rc_command_abs = std::abs(std::clamp(stick, -1.0, 1.0));
    double rc_command = std::clamp(stick, -1.0, 1.0);
    rc_command = rc_command * power3(rc_command_abs) * profile.expo +
            rc_command * (1.0 - profile.expo);

    double rc_rate = profile.rc_rate;
    if (rc_rate > 2.0) {
        rc_rate += 14.54 * (rc_rate - 2.0);
    }

    double angle_rate = 200.0 * rc_rate * rc_command;
    if (profile.super_rate != 0.0) {
        const double super_factor = 1.0 / std::clamp(1.0 - rc_command_abs * profile.super_rate, 0.01, 1.0);
        angle_rate *= super_factor;
    }
    return angle_rate;
}

double betaflight_stick_for_rate_degrees_per_second(double rate_degrees_per_second, const RateProfile &profile) {
    if (!std::isfinite(rate_degrees_per_second)) {
        return 0.0;
    }
    const double target_sign = rate_degrees_per_second < 0.0 ? -1.0 : 1.0;
    const double target = std::abs(rate_degrees_per_second);
    const double maximum = betaflight_rate_degrees_per_second(1.0, profile);
    if (!std::isfinite(maximum) || maximum <= 0.0) {
        return 0.0;
    }
    if (target >= maximum) {
        return target_sign;
    }
    double low = 0.0;
    double high = 1.0;
    for (int iteration = 0; iteration < 64; ++iteration) {
        const double middle = (low + high) * 0.5;
        if (betaflight_rate_degrees_per_second(middle, profile) < target) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return target_sign * (low + high) * 0.5;
}

bool FlightController::arm(double throttle) {
    if (!std::isfinite(throttle) || throttle < 0.0) {
        arm_reject_code_ = "invalid_throttle";
        return false;
    }
    if (throttle > 0.05) {
        arm_reject_code_ = "throttle_not_low";
        return false;
    }
    armed_ = true;
    arm_reject_code_ = "";
    return true;
}

void FlightController::disarm() {
    armed_ = false;
    motor_thrust_newtons_ = 0.0;
    altitude_hold_captured_ = false;
    altitude_hold_target_m_ = 0.0;
    altitude_hold_filtered_altitude_m_ = 0.0;
    altitude_hold_vertical_speed_mps_ = 0.0;
    altitude_hold_trim_throttle_ = 0.0;
    altitude_hold_just_captured_ = false;
    rate_integral_ = {};
    previous_target_rates_y_up_ = {};
    motor_saturation_latched_ = {};
    pid_saturation_latched_ = {};
    pid_timing_stats_ = {};
    telemetry_buffers_ = {};
    telemetry_read_index_ = 0;
    next_telemetry_publish_s_ = 0.0;
}

bool FlightController::armed() const {
    return armed_;
}

const std::string &FlightController::arm_reject_code() const {
    return arm_reject_code_;
}

void FlightController::reset_integrators() {
    ++integrator_reset_count_;
    rate_integral_ = {};
    previous_target_rates_y_up_ = {};
}

int FlightController::integrator_reset_count() const {
    return integrator_reset_count_;
}

double FlightController::motor_thrust_newtons() const {
    return motor_thrust_newtons_;
}

void FlightController::capture_altitude_hold(double target_altitude_m) {
    if (!armed_) {
        return;
    }
    altitude_hold_captured_ = std::isfinite(target_altitude_m);
    altitude_hold_target_m_ = altitude_hold_captured_ ? target_altitude_m : 0.0;
    altitude_hold_filtered_altitude_m_ = altitude_hold_target_m_;
    altitude_hold_vertical_speed_mps_ = 0.0;
    altitude_hold_just_captured_ = altitude_hold_captured_;
}

const PidTimingStats &FlightController::pid_timing_stats() const {
    return pid_timing_stats_;
}

const TelemetrySnapshot &FlightController::telemetry_snapshot() const {
    return telemetry_buffers_[telemetry_read_index_];
}

void FlightController::clear_propwash_telemetry() {
    const int write_index = 1 - telemetry_read_index_;
    telemetry_buffers_[write_index] = telemetry_buffers_[telemetry_read_index_];
    telemetry_buffers_[write_index].propwash_disturbance_rad_s2 = {};
    telemetry_read_index_ = write_index;
}

MotorCommands FlightController::control_substep(
        RigidBodyState &state,
        const SimulationConfig &config,
        double throttle,
        const Vec3 &desired_rates_y_up,
        double dt,
        std::array<double, 3> &pid_output,
        std::array<bool, 3> &pid_saturated) {
    MotorCommands commands;
    if (!armed_) {
        previous_target_rates_y_up_ = {};
        return commands;
    }

    const std::array<double, 3> desired = {
            desired_rates_y_up.x,
            desired_rates_y_up.y,
            desired_rates_y_up.z,
    };
    std::array<double, 3> shaped{};
    for (std::size_t index = 0; index < shaped.size(); ++index) {
        shaped[index] = shaped_rate(desired[index], previous_target_rates_y_up_[index], dt);
        previous_target_rates_y_up_[index] = shaped[index];
    }

    const Vec3 rate_error_y_up{
            shaped[0] - state.angular_velocity.x,
            shaped[1] - state.angular_velocity.y,
            shaped[2] - state.angular_velocity.z,
    };
    const std::array<double, 3> errors = {rate_error_y_up.x, rate_error_y_up.y, rate_error_y_up.z};
    std::array<double, 3> target_torque_y_up = {};
    for (std::size_t index = 0; index < target_torque_y_up.size(); ++index) {
        rate_integral_[index] = std::clamp(
                rate_integral_[index] + errors[index] * kRateI * std::max(dt, 0.0),
                -kRateIntegralLimitNm,
                kRateIntegralLimitNm);
        target_torque_y_up[index] = errors[index] * kRateP + rate_integral_[index];
    }
    const Vec3 target_torque_frd = y_up_to_frd({
            target_torque_y_up[0],
            target_torque_y_up[1],
            target_torque_y_up[2],
    });
    const std::array<double, 3> target_torque = {
            target_torque_frd.x,
            target_torque_frd.y,
            target_torque_frd.z,
    };
    for (std::size_t index = 0; index < target_torque.size(); ++index) {
        pid_output[index] = target_torque[index];
        pid_saturated[index] = std::abs(target_torque[index]) >= kRateIntegralLimitNm + kMaxRateRadS * kRateP;
    }

    const QuadXMixerResult mixed = quad_x_mix_thrust(
            config,
            target_thrust_newtons(config, throttle),
            {target_torque[0], target_torque[1], target_torque[2]});
    if (!mixed.valid) {
        commands.normalized.fill(std::numeric_limits<double>::quiet_NaN());
        return commands;
    }
    for (std::size_t index = 0; index < commands.normalized.size(); ++index) {
        commands.normalized[index] = mixed.normalized[index];
    }
    bool motor_saturated = false;
    for (std::size_t index = 0; index < commands.normalized.size(); ++index) {
        const double command = commands.normalized[index];
        motor_saturated = motor_saturated || command <= 1.0e-12 || command >= 1.0 - 1.0e-12;
        motor_saturation_latched_[index] = motor_saturation_latched_[index] ||
                command <= 1.0e-12 || command >= 1.0 - 1.0e-12;
    }
    for (std::size_t index = 0; index < pid_saturated.size(); ++index) {
        pid_saturated[index] = pid_saturated[index] || mixed.axis_saturated[index] ||
                (motor_saturated && std::abs(target_torque[index]) > 1.0e-12) ||
                (throttle >= 1.0 - 1.0e-12 && std::abs(target_torque[index]) > 1.0e-12);
    }
    pid_saturated[1] = pid_saturated[1] || mixed.collective_saturated;
    for (std::size_t index = 0; index < pid_saturated.size(); ++index) {
        pid_saturation_latched_[index] = pid_saturation_latched_[index] || pid_saturated[index];
    }
    return commands;
}

void FlightController::maybe_publish_telemetry(
        const TrajectorySample &sample,
        const SimulationConfig &config,
        double throttle,
        const std::array<double, 3> &pid_output,
        const std::array<bool, 3> &pid_saturated,
        const std::string &mode) {
    const double sample_time_s = sample.time_seconds;
    if (telemetry_publish_count_ > 0 &&
            sample_time_s + 1e-12 < next_telemetry_publish_s_) {
        return;
    }

    TelemetrySnapshot snapshot;
    snapshot.timestamp_us = static_cast<std::uint64_t>(std::llround(sample_time_s * 1000000.0));
    snapshot.publish_count = telemetry_publish_count_ + 1;
    snapshot.armed = armed_;
    snapshot.mode = mode;

    const double throttle_clamped = armed_ ? std::clamp(throttle, 0.0, 1.0) : 0.0;
    std::array<double, 4> motor_speeds{};
    for (std::size_t index = 0; index < snapshot.motors.size(); ++index) {
        MotorTelemetry &motor = snapshot.motors[index];
        motor.thrust_newtons = armed_ ? sample.state.motor_thrust_newtons[index] : 0.0;
        const double thrust_fraction = config.per_motor.max_thrust_per_motor_newtons > 0.0
                ? std::clamp(motor.thrust_newtons / config.per_motor.max_thrust_per_motor_newtons, 0.0, 1.0)
                : 0.0;
        motor.current_a = armed_ ? config.per_motor.max_current_per_motor_a * thrust_fraction : 0.0;
        motor_speeds[index] = motor_speed_rad_s_from_thrust(
                motor.thrust_newtons,
                config.per_motor.max_thrust_per_motor_newtons,
                config.max_motor_rpm);
        motor.speed_rad_s = motor_speeds[index];
        motor.saturated = armed_ && (motor_saturation_latched_[index] || throttle_clamped >= 1.0 - 1e-9 ||
                (config.per_motor.max_thrust_per_motor_newtons > 0.0 &&
                        motor.thrust_newtons >= config.per_motor.max_thrust_per_motor_newtons - 1e-9));
    }

    snapshot.ground_effect_gain = a4_ground_effect_lift_newtons(config.a4_ground_effect, sample.state.position.y);
    snapshot.wind_world_mps = config.wind_world_mps;
    snapshot.wind_body_mps = y_up_to_frd(world_to_body(sample.state.orientation, config.wind_world_mps));
    snapshot.turbulence_intensity = std::sqrt(
            config.wind_turbulence_mps.x * config.wind_turbulence_mps.x +
            config.wind_turbulence_mps.y * config.wind_turbulence_mps.y +
            config.wind_turbulence_mps.z * config.wind_turbulence_mps.z);
    snapshot.propwash_disturbance_rad_s2 = sample.propwash_disturbance_rad_s2;
    const Vec3 relative_air_velocity{
            sample.state.velocity.x - config.wind_world_mps.x,
            sample.state.velocity.y - config.wind_world_mps.y,
            sample.state.velocity.z - config.wind_world_mps.z};
    snapshot.drag_body_n = a3_drag_force_body(
            config.a3_drag,
            sample.state.orientation,
            relative_air_velocity,
            motor_speeds);
    snapshot.battery.voltage_v = loaded_voltage_v(config, throttle_clamped);
    snapshot.battery.sag_v = std::max(0.0, config.battery_nominal_voltage_v - snapshot.battery.voltage_v);
    snapshot.battery.remaining_mah = config.battery_remaining_mah;
    for (std::size_t index = 0; index < snapshot.pid.size(); ++index) {
        snapshot.pid[index].output = pid_output[index];
        snapshot.pid[index].saturated = pid_saturated[index] || pid_saturation_latched_[index];
    }

    const int write_index = 1 - telemetry_read_index_;
    telemetry_buffers_[write_index] = snapshot;
    telemetry_read_index_ = write_index;
    telemetry_publish_count_ = snapshot.publish_count;
    motor_saturation_latched_ = {};
    pid_saturation_latched_ = {};
    if (next_telemetry_publish_s_ <= 0.0) {
        next_telemetry_publish_s_ = 1.0 / kTelemetrySnapshotHz;
    }
    while (next_telemetry_publish_s_ <= sample_time_s + 1e-12) {
        next_telemetry_publish_s_ += 1.0 / kTelemetrySnapshotHz;
    }
}

TrajectorySample FlightController::step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command) {
    return step_angle_mode(state, clock, config, command, state.orientation);
}

TrajectorySample FlightController::step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        const Quat &estimated_attitude) {
    if (!armed_) {
        state.motor_thrust_newtons = {};
    }
    SimulationConfig frame_config = config;
    const double throttle = std::clamp(command.throttle, 0.0, 1.0);
    pid_timing_stats_ = armed_ ? PidTimingStats{static_cast<double>(frame_config.substep_hz), 0.0, 0} : PidTimingStats{};
    std::array<double, 3> pid_output = {0.0, 0.0, 0.0};
    std::array<bool, 3> pid_saturated = {false, false, false};
    const Vec3 desired_rates_y_up{
            (radians(command.pitch_degrees) - angle_x(estimated_attitude)) * kAngleP,
            radians(command.yaw_rate_degrees_per_second),
            (radians(command.roll_degrees) - angle_z(estimated_attitude)) * kAngleP,
    };
    const TrajectorySample sample = step_per_motor_physics_frame(state, clock, frame_config, [&](double dt) {
        const MotorCommands commands_for_substep = control_substep(
                state,
                frame_config,
                throttle,
                desired_rates_y_up,
                dt,
                pid_output,
                pid_saturated);
        const double target_dt = frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0;
        if (armed_ && target_dt > 0.0) {
            pid_timing_stats_.p99_jitter_fraction = std::max(
                    pid_timing_stats_.p99_jitter_fraction,
                    std::abs(dt - target_dt) / target_dt);
            ++pid_timing_stats_.samples;
        }
        return commands_for_substep;
    });
    motor_thrust_newtons_ = 0.0;
    for (double thrust : sample.state.motor_thrust_newtons) {
        motor_thrust_newtons_ += thrust;
    }
    maybe_publish_telemetry(sample, frame_config, throttle, pid_output, pid_saturated, "ANGLE");
    return sample;
}

TrajectorySample FlightController::step_acro_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const AcroCommand &command) {
    if (!armed_) {
        state.motor_thrust_newtons = {};
    }
    SimulationConfig frame_config = config;
    const double throttle = std::clamp(command.throttle, 0.0, 1.0);
    pid_timing_stats_ = armed_ ? PidTimingStats{static_cast<double>(frame_config.substep_hz), 0.0, 0} : PidTimingStats{};
    std::array<double, 3> pid_output = {0.0, 0.0, 0.0};
    std::array<bool, 3> pid_saturated = {false, false, false};
    const Vec3 desired_rates_y_up{
            radians(betaflight_rate_degrees_per_second(command.pitch_stick, command.rates)),
            radians(betaflight_rate_degrees_per_second(command.yaw_stick, command.rates)),
            radians(betaflight_rate_degrees_per_second(command.roll_stick, command.rates)),
    };
    const TrajectorySample sample = step_per_motor_physics_frame(state, clock, frame_config, [&](double dt) {
        const MotorCommands commands_for_substep = control_substep(
                state,
                frame_config,
                throttle,
                desired_rates_y_up,
                dt,
                pid_output,
                pid_saturated);
        const double target_dt = frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0;
        if (armed_ && target_dt > 0.0) {
            pid_timing_stats_.p99_jitter_fraction = std::max(
                    pid_timing_stats_.p99_jitter_fraction,
                    std::abs(dt - target_dt) / target_dt);
            ++pid_timing_stats_.samples;
        }
        return commands_for_substep;
    });
    motor_thrust_newtons_ = 0.0;
    for (double thrust : sample.state.motor_thrust_newtons) {
        motor_thrust_newtons_ += thrust;
    }
    maybe_publish_telemetry(sample, frame_config, throttle, pid_output, pid_saturated, "ACRO");
    return sample;
}

TrajectorySample FlightController::step_altitude_hold_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        double measured_altitude_m,
        const Quat &estimated_attitude) {
    if (!armed_) {
        state.motor_thrust_newtons = {};
        altitude_hold_captured_ = false;
        altitude_hold_target_m_ = 0.0;
        altitude_hold_filtered_altitude_m_ = 0.0;
        altitude_hold_vertical_speed_mps_ = 0.0;
        altitude_hold_trim_throttle_ = 0.0;
        altitude_hold_just_captured_ = false;
    }
    double target_throttle = 0.0;
    SimulationConfig frame_config = config;
    if (armed_) {
        if (!altitude_hold_captured_) {
            capture_altitude_hold(measured_altitude_m);
        }
        if (config.hover_throttle > 0.0) {
            if (altitude_hold_trim_throttle_ <= 0.0) {
                altitude_hold_trim_throttle_ = std::clamp(command.throttle, 0.0, 1.0);
            }
        }

        const double control_dt = frame_config.physics_hz > 0
                ? 1.0 / static_cast<double>(frame_config.physics_hz)
                : (frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0);
        const double estimate_alpha = alpha_from_tau(control_dt, kAltitudeHoldEstimateTauS);
        const double vertical_speed_mps = std::isfinite(state.velocity.y) ? state.velocity.y : 0.0;
        altitude_hold_filtered_altitude_m_ += vertical_speed_mps * control_dt;
        altitude_hold_filtered_altitude_m_ +=
                (measured_altitude_m - altitude_hold_filtered_altitude_m_) * estimate_alpha;
        altitude_hold_vertical_speed_mps_ = vertical_speed_mps;
        const double hover_thrust = frame_config.mass_kg * frame_config.gravity_mps2;
        const double current_throttle = hover_thrust > 0.0 && frame_config.hover_throttle > 0.0
                ? std::clamp(motor_thrust_newtons_ * frame_config.hover_throttle / hover_thrust, 0.0, 1.0)
                : std::clamp(command.throttle, 0.0, 1.0);
        double altitude_error_m = altitude_hold_target_m_ - altitude_hold_filtered_altitude_m_;
        const bool inside_noise_band = std::abs(altitude_error_m) <= kAltitudeHoldNoiseDeadbandM;
        if (inside_noise_band) {
            altitude_error_m = 0.0;
        }
        target_throttle = current_throttle;
        if (altitude_hold_just_captured_) {
            altitude_hold_trim_throttle_ = std::clamp(command.throttle, 0.0, 1.0);
            target_throttle = altitude_hold_trim_throttle_;
            altitude_hold_just_captured_ = false;
        } else {
            target_throttle = std::clamp(
                    altitude_hold_trim_throttle_ +
                            altitude_error_m * kAltitudeHoldKp -
                            altitude_hold_vertical_speed_mps_ * kAltitudeHoldKd,
                    0.0,
                    1.0);
        }
    }
    pid_timing_stats_ = armed_ ? PidTimingStats{static_cast<double>(frame_config.substep_hz), 0.0, 0} : PidTimingStats{};
    std::array<double, 3> pid_output = {0.0, 0.0, 0.0};
    std::array<bool, 3> pid_saturated = {false, false, false};
    const Vec3 desired_rates_y_up{
            (radians(command.pitch_degrees) - angle_x(estimated_attitude)) * kAngleP,
            radians(command.yaw_rate_degrees_per_second),
            (radians(command.roll_degrees) - angle_z(estimated_attitude)) * kAngleP,
    };
    const TrajectorySample sample = step_per_motor_physics_frame(state, clock, frame_config, [&](double dt) {
        const MotorCommands commands_for_substep = control_substep(
                state,
                frame_config,
                target_throttle,
                desired_rates_y_up,
                dt,
                pid_output,
                pid_saturated);
        if (armed_) {
            pid_saturated[1] = pid_saturated[1] || target_throttle <= 0.0 || target_throttle >= 1.0;
        }
        const double target_dt = frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0;
        if (armed_ && target_dt > 0.0) {
            pid_timing_stats_.p99_jitter_fraction = std::max(
                    pid_timing_stats_.p99_jitter_fraction,
                    std::abs(dt - target_dt) / target_dt);
            ++pid_timing_stats_.samples;
        }
        return commands_for_substep;
    });
    motor_thrust_newtons_ = 0.0;
    for (double thrust : sample.state.motor_thrust_newtons) {
        motor_thrust_newtons_ += thrust;
    }
    maybe_publish_telemetry(sample, frame_config, target_throttle, pid_output, pid_saturated, "ALTITUDE_HOLD");
    return sample;
}

void FlightController::reset_flight(RigidBodyState &state, SimulationClock &clock) {
    reset_integrators();
    motor_thrust_newtons_ = 0.0;
    altitude_hold_captured_ = false;
    altitude_hold_target_m_ = 0.0;
    altitude_hold_filtered_altitude_m_ = 0.0;
    altitude_hold_vertical_speed_mps_ = 0.0;
    altitude_hold_trim_throttle_ = 0.0;
    altitude_hold_just_captured_ = false;
    previous_target_rates_y_up_ = {};
    motor_saturation_latched_ = {};
    pid_saturation_latched_ = {};
    telemetry_buffers_ = {};
    telemetry_read_index_ = 0;
    next_telemetry_publish_s_ = 0.0;
    telemetry_publish_count_ = 0;
    state = {};
    clock = {};
}

} // namespace aerosim
