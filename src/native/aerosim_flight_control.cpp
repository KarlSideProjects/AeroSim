#include "aerosim_flight_control.hpp"

#include <algorithm>
#include <cmath>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kAngleModeGain = 20.0;
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
    return step_physics_frame(state, clock, frame_config, [&](double dt) {
        if (armed_) {
            const double target_thrust = target_thrust_newtons(frame_config, throttle);
            motor_thrust_newtons_ = first_order_motor_response(
                    motor_thrust_newtons_,
                    target_thrust,
                    frame_config.motor_tau_s,
                    dt);
            frame_config.total_thrust_newtons = motor_thrust_newtons_;
            state.angular_velocity.x = bounded_rate((radians(command.pitch_degrees) - angle_x(estimated_attitude)) * kAngleModeGain);
            state.angular_velocity.y = radians(command.yaw_rate_degrees_per_second);
            state.angular_velocity.z = bounded_rate((radians(command.roll_degrees) - angle_z(estimated_attitude)) * kAngleModeGain);
        } else {
            motor_thrust_newtons_ = 0.0;
            frame_config.total_thrust_newtons = 0.0;
            state.angular_velocity = {};
        }
        const double target_dt = frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0;
        if (target_dt > 0.0) {
            pid_timing_stats_.p99_jitter_fraction = std::max(
                    pid_timing_stats_.p99_jitter_fraction,
                    std::abs(dt - target_dt) / target_dt);
            ++pid_timing_stats_.samples;
        }
    });
}

TrajectorySample FlightController::step_acro_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const AcroCommand &command) {
    SimulationConfig frame_config = config;
    const double throttle = std::clamp(command.throttle, 0.0, 1.0);
    pid_timing_stats_ = {static_cast<double>(frame_config.substep_hz), 0.0, 0};
    return step_physics_frame(state, clock, frame_config, [&](double dt) {
        if (armed_) {
            const double target_thrust = target_thrust_newtons(frame_config, throttle);
            motor_thrust_newtons_ = first_order_motor_response(
                    motor_thrust_newtons_,
                    target_thrust,
                    frame_config.motor_tau_s,
                    dt);
            frame_config.total_thrust_newtons = motor_thrust_newtons_;
            state.angular_velocity.x = radians(betaflight_rate_degrees_per_second(command.pitch_stick, command.rates));
            state.angular_velocity.y = radians(betaflight_rate_degrees_per_second(command.yaw_stick, command.rates));
            state.angular_velocity.z = radians(betaflight_rate_degrees_per_second(command.roll_stick, command.rates));
        } else {
            motor_thrust_newtons_ = 0.0;
            frame_config.total_thrust_newtons = 0.0;
            state.angular_velocity = {};
        }
        const double target_dt = frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0;
        if (target_dt > 0.0) {
            pid_timing_stats_.p99_jitter_fraction = std::max(
                    pid_timing_stats_.p99_jitter_fraction,
                    std::abs(dt - target_dt) / target_dt);
            ++pid_timing_stats_.samples;
        }
    });
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
    return step_physics_frame(state, clock, frame_config, [&](double dt) {
        if (armed_) {
            motor_thrust_newtons_ = first_order_motor_response(
                    motor_thrust_newtons_,
                    target_thrust,
                    frame_config.motor_tau_s,
                    dt);
            frame_config.total_thrust_newtons = motor_thrust_newtons_;
            state.angular_velocity.x = bounded_rate((radians(command.pitch_degrees) - angle_x(estimated_attitude)) * kAngleModeGain);
            state.angular_velocity.y = radians(command.yaw_rate_degrees_per_second);
            state.angular_velocity.z = bounded_rate((radians(command.roll_degrees) - angle_z(estimated_attitude)) * kAngleModeGain);
        } else {
            motor_thrust_newtons_ = 0.0;
            frame_config.total_thrust_newtons = 0.0;
            state.angular_velocity = {};
        }
        const double target_dt = frame_config.substep_hz > 0 ? 1.0 / static_cast<double>(frame_config.substep_hz) : 0.0;
        if (target_dt > 0.0) {
            pid_timing_stats_.p99_jitter_fraction = std::max(
                    pid_timing_stats_.p99_jitter_fraction,
                    std::abs(dt - target_dt) / target_dt);
            ++pid_timing_stats_.samples;
        }
    });
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
    state = {};
    clock = {};
}

} // namespace aerosim
