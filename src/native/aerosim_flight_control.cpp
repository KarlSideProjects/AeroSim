#include "aerosim_flight_control.hpp"

#include "aerosim_aerodynamics.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kRadiansPerSecondPerRpm = 2.0 * kPi / 60.0;
constexpr double kAngleModeGain = 20.0;
constexpr double kAltitudeHoldEstimateTauS = 2.0;
constexpr double kAltitudeHoldKp = 0.08;
constexpr double kAltitudeHoldKd = 0.20;
constexpr double kAltitudeHoldNoiseDeadbandM = 0.15;
constexpr double kRateKp = 30.0;
constexpr double kRateKd = 30.0;

double radians(double degrees) {
    return degrees * kPi / 180.0;
}

double angle_x(const Quat &q) {
    return 2.0 * std::atan2(q.x, q.w);
}

double angle_z(const Quat &q) {
    return 2.0 * std::atan2(q.z, q.w);
}

double bounded_rate(double rate) {
    return std::clamp(rate, -6.0, 6.0);
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

MotorCommands quad_x_commands(
        const SimulationConfig &config,
        double collective_thrust,
        const Vec3 &target_rate_y_up,
        const Vec3 &actual_rate_y_up,
        double control_dt) {
    MotorCommands commands;
    if (control_dt <= 0.0 || config.per_motor.max_thrust_per_motor_newtons <= 0.0) {
        return commands;
    }
    double roll_denominator = 0.0;
    double pitch_denominator = 0.0;
    double yaw_denominator = 0.0;
    std::array<Vec3, 4> coefficients;
    for (std::size_t index = 0; index < coefficients.size(); ++index) {
        const Vec3 position = frd_to_y_up(config.per_motor.position_frd[index]);
        coefficients[index] = {-position.z, -config.per_motor.spin_direction[index] * config.per_motor.yaw_torque_per_newton, position.x};
        roll_denominator += coefficients[index].x * coefficients[index].x;
        yaw_denominator += coefficients[index].y * coefficients[index].y;
        pitch_denominator += coefficients[index].z * coefficients[index].z;
    }
    const Vec3 raw_torque{
            config.per_motor.inertia_kg_m2.x * (kRateKp * target_rate_y_up.x - kRateKd * actual_rate_y_up.x),
            config.per_motor.inertia_kg_m2.y * (kRateKp * target_rate_y_up.y - kRateKd * actual_rate_y_up.y),
            config.per_motor.inertia_kg_m2.z * (kRateKp * target_rate_y_up.z - kRateKd * actual_rate_y_up.z),
    };
    const double base_thrust = collective_thrust / 4.0;
    double torque_scale = 1.0;
    for (const Vec3 &coefficient : coefficients) {
        const double thrust_delta = coefficient.x * raw_torque.x / roll_denominator +
                coefficient.y * raw_torque.y / yaw_denominator +
                coefficient.z * raw_torque.z / pitch_denominator;
        if (thrust_delta > 0.0) {
            torque_scale = std::min(
                    torque_scale,
                    (config.per_motor.max_thrust_per_motor_newtons - base_thrust) / thrust_delta);
        } else if (thrust_delta < 0.0) {
            torque_scale = std::min(torque_scale, base_thrust / -thrust_delta);
        }
    }
    torque_scale = std::clamp(torque_scale, 0.0, 1.0);
    const Vec3 torque{
            raw_torque.x * torque_scale,
            raw_torque.y * torque_scale,
            raw_torque.z * torque_scale,
    };
    for (std::size_t index = 0; index < commands.normalized.size(); ++index) {
        const Vec3 &coefficient = coefficients[index];
        const double thrust = base_thrust +
                coefficient.x * torque.x / roll_denominator +
                coefficient.y * torque.y / yaw_denominator +
                coefficient.z * torque.z / pitch_denominator;
        commands.normalized[index] = std::clamp(thrust / config.per_motor.max_thrust_per_motor_newtons, 0.0, 1.0);
    }
    return commands;
}

double total_motor_thrust(const RigidBodyState &state) {
    return std::accumulate(state.motor_thrust_newtons.begin(), state.motor_thrust_newtons.end(), 0.0);
}

} // namespace

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

bool FlightController::armed() const {
    return armed_;
}

const std::string &FlightController::arm_reject_code() const {
    return arm_reject_code_;
}

void FlightController::reset_integrators() {
    ++integrator_reset_count_;
}

int FlightController::integrator_reset_count() const {
    return integrator_reset_count_;
}

double FlightController::motor_thrust_newtons() const {
    return motor_thrust_newtons_;
}

void FlightController::capture_altitude_hold(double target_altitude_m) {
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
    const double max_per_motor_thrust = available_thrust_cap_newtons(config, throttle_clamped) /
            static_cast<double>(snapshot.motors.size());
    const double total_current = armed_ ? config.max_total_current_a * throttle_clamped : 0.0;
    const double max_motor_rpm = config.max_motor_rpm > 0.0 ? config.max_motor_rpm : 0.0;
    for (std::size_t index = 0; index < snapshot.motors.size(); ++index) {
        MotorTelemetry &motor = snapshot.motors[index];
        motor.thrust_newtons = armed_ ? sample.state.motor_thrust_newtons[index] : 0.0;
        motor.current_a = total_current / static_cast<double>(snapshot.motors.size());
        const double motor_rpm = max_per_motor_thrust > 0.0
                ? max_motor_rpm * std::sqrt(std::clamp(motor.thrust_newtons / max_per_motor_thrust, 0.0, 1.0))
                : 0.0;
        motor.speed_rad_s = motor_rpm * kRadiansPerSecondPerRpm;
        motor.saturated = motor_saturated_since_snapshot_[index];
    }

    snapshot.ground_effect_gain = a4_ground_effect_lift_newtons(config.a4_ground_effect, sample.state.position.y);
    snapshot.drag_body_n = a3_drag_force_body(config.a3_drag, sample.state.orientation, sample.state.velocity);
    snapshot.battery.voltage_v = loaded_voltage_v(config, throttle_clamped);
    snapshot.battery.sag_v = std::max(0.0, config.battery_nominal_voltage_v - snapshot.battery.voltage_v);
    snapshot.battery.remaining_mah = config.battery_remaining_mah;
    for (std::size_t index = 0; index < snapshot.pid.size(); ++index) {
        snapshot.pid[index].output = pid_output[index];
        snapshot.pid[index].saturated = pid_saturated[index];
    }

    const int write_index = 1 - telemetry_read_index_;
    telemetry_buffers_[write_index] = snapshot;
    telemetry_read_index_ = write_index;
    telemetry_publish_count_ = snapshot.publish_count;
    motor_saturated_since_snapshot_ = {false, false, false, false};
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
    SimulationConfig frame_config = config;
    const double throttle = std::clamp(command.throttle, 0.0, 1.0);
    pid_timing_stats_ = {static_cast<double>(frame_config.substep_hz), 0.0, 0};
    const double roll_output = bounded_rate((radians(command.roll_degrees) - angle_x(estimated_attitude)) * kAngleModeGain);
    const double pitch_output = bounded_rate((radians(command.pitch_degrees) - angle_z(estimated_attitude)) * kAngleModeGain);
    const Vec3 target_rate = armed_ ? Vec3{roll_output, -radians(command.yaw_rate_degrees_per_second), pitch_output} : Vec3{};
    const double collective_thrust = armed_ ? target_thrust_newtons(frame_config, throttle) : 0.0;
    const TrajectorySample sample = step_per_motor_physics_frame(
            state,
            clock,
            frame_config,
            [&](double control_dt) {
                return quad_x_commands(frame_config, collective_thrust, target_rate, state.angular_velocity, control_dt);
            });
    for (std::size_t index = 0; index < state.motor_saturated.size(); ++index) {
        motor_saturated_since_snapshot_[index] = motor_saturated_since_snapshot_[index] || state.motor_saturated[index];
        state.motor_saturated[index] = false;
    }
    motor_thrust_newtons_ = total_motor_thrust(sample.state);
    pid_timing_stats_.samples = sample.substeps;
    const std::array<double, 3> pid_output = {roll_output, pitch_output, -radians(command.yaw_rate_degrees_per_second)};
    const std::array<bool, 3> pid_saturated = {std::abs(roll_output) >= 6.0, std::abs(pitch_output) >= 6.0, false};
    maybe_publish_telemetry(sample, frame_config, throttle, pid_output, pid_saturated, "ANGLE");
    return sample;
}

TrajectorySample FlightController::step_acro_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const AcroCommand &command) {
    SimulationConfig frame_config = config;
    const double throttle = std::clamp(command.throttle, 0.0, 1.0);
    pid_timing_stats_ = {static_cast<double>(frame_config.substep_hz), 0.0, 0};
    const Vec3 target_rate = armed_ ? Vec3{
            radians(betaflight_rate_degrees_per_second(command.roll_stick, command.rates)),
            -radians(betaflight_rate_degrees_per_second(command.yaw_stick, command.rates)),
            radians(betaflight_rate_degrees_per_second(command.pitch_stick, command.rates)),
    } : Vec3{};
    const double collective_thrust = armed_ ? target_thrust_newtons(frame_config, throttle) : 0.0;
    const TrajectorySample sample = step_per_motor_physics_frame(
            state,
            clock,
            frame_config,
            [&](double control_dt) {
                return quad_x_commands(frame_config, collective_thrust, target_rate, state.angular_velocity, control_dt);
            });
    for (std::size_t index = 0; index < state.motor_saturated.size(); ++index) {
        motor_saturated_since_snapshot_[index] = motor_saturated_since_snapshot_[index] || state.motor_saturated[index];
        state.motor_saturated[index] = false;
    }
    motor_thrust_newtons_ = total_motor_thrust(sample.state);
    pid_timing_stats_.samples = sample.substeps;
    const std::array<double, 3> pid_output = {target_rate.x, target_rate.z, target_rate.y};
    const std::array<bool, 3> pid_saturated = {false, false, false};
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
    if (!altitude_hold_captured_) {
        capture_altitude_hold(measured_altitude_m);
    }
    if (config.hover_throttle > 0.0) {
        if (altitude_hold_trim_throttle_ <= 0.0) {
            altitude_hold_trim_throttle_ = std::clamp(command.throttle, 0.0, 1.0);
        }
    }

    SimulationConfig frame_config = config;
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
    double target_throttle = current_throttle;
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
    const double target_thrust = armed_ ? target_thrust_newtons(frame_config, target_throttle) : 0.0;
    pid_timing_stats_ = {static_cast<double>(frame_config.substep_hz), 0.0, 0};
    const double roll_output = bounded_rate((radians(command.roll_degrees) - angle_x(estimated_attitude)) * kAngleModeGain);
    const double pitch_output = bounded_rate((radians(command.pitch_degrees) - angle_z(estimated_attitude)) * kAngleModeGain);
    const Vec3 target_rate = armed_ ? Vec3{roll_output, -radians(command.yaw_rate_degrees_per_second), pitch_output} : Vec3{};
    const TrajectorySample sample = step_per_motor_physics_frame(
            state,
            clock,
            frame_config,
            [&](double rate_control_dt) {
                return quad_x_commands(frame_config, target_thrust, target_rate, state.angular_velocity, rate_control_dt);
            });
    for (std::size_t index = 0; index < state.motor_saturated.size(); ++index) {
        motor_saturated_since_snapshot_[index] = motor_saturated_since_snapshot_[index] || state.motor_saturated[index];
        state.motor_saturated[index] = false;
    }
    motor_thrust_newtons_ = total_motor_thrust(sample.state);
    pid_timing_stats_.samples = sample.substeps;
    const std::array<double, 3> pid_output = {roll_output, pitch_output, -radians(command.yaw_rate_degrees_per_second)};
    const std::array<bool, 3> pid_saturated = {std::abs(roll_output) >= 6.0, std::abs(pitch_output) >= 6.0, target_throttle <= 0.0 || target_throttle >= 1.0};
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
    telemetry_buffers_ = {};
    telemetry_read_index_ = 0;
    next_telemetry_publish_s_ = 0.0;
    telemetry_publish_count_ = 0;
    state = {};
    clock = {};
}

} // namespace aerosim
