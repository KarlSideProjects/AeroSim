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
constexpr double kAngleP = 15.0;
constexpr double kRateP = 0.600;
constexpr double kRatePFeedForward = 0.0;
constexpr double kRateI = 0.020;
constexpr double kRateD = 0.005;
constexpr double kMaxRateRadS = 16.0;
constexpr double kTargetRateAccelerationRadS2 = 120.0;
constexpr double kRateIntegralLimitNm = 0.20;
constexpr double kAngleInputTimeConstantS = 0.05;
constexpr double kDerivativeFilterTimeConstantS = 0.003;
constexpr double kAltitudeHoldEstimateTauS = 2.0;
constexpr double kAltitudeHoldKp = 0.08;
constexpr double kAltitudeHoldKd = 0.20;

double radians(double degrees) {
    return degrees * kPi / 180.0;
}

Quat conjugate(const Quat &q) {
    return {-q.x, -q.y, -q.z, q.w};
}

Quat normalized_quat(const Quat &q) {
    const double norm = quat_norm(q);
    if (!std::isfinite(norm) || norm <= 0.0) {
        return {};
    }
    return {q.x / norm, q.y / norm, q.z / norm, q.w / norm};
}

double wrap_pi(double angle) {
    return normalize_angle_radians(angle);
}

double move_toward(double current, double target, double maximum_delta) {
    return current + std::clamp(target - current, -maximum_delta, maximum_delta);
}

Vec3 frd_euler(const Quat &attitude_y_up) {
    constexpr double kHalfSqrt2 = 0.70710678118654752440;
    const Quat basis{ kHalfSqrt2, 0.0, 0.0, kHalfSqrt2 };
    const Quat frd = normalized_quat(multiply(multiply(conjugate(basis), normalized_quat(attitude_y_up)), basis));
    const double roll = std::atan2(
            2.0 * (frd.w * frd.x + frd.y * frd.z),
            1.0 - 2.0 * (frd.x * frd.x + frd.y * frd.y));
    const double pitch = std::asin(std::clamp(2.0 * (frd.w * frd.y - frd.z * frd.x), -1.0, 1.0));
    const double yaw = std::atan2(
            2.0 * (frd.w * frd.z + frd.x * frd.y),
            1.0 - 2.0 * (frd.y * frd.y + frd.z * frd.z));
    return {roll, pitch, yaw};
}

Quat frd_attitude(const Vec3 &angles) {
    constexpr double kHalfSqrt2 = 0.70710678118654752440;
    const double cr = std::cos(angles.x * 0.5);
    const double sr = std::sin(angles.x * 0.5);
    const double cp = std::cos(angles.y * 0.5);
    const double sp = std::sin(angles.y * 0.5);
    const double cy = std::cos(angles.z * 0.5);
    const double sy = std::sin(angles.z * 0.5);
    const Quat frd{
            sr * cp * cy - cr * sp * sy,
            cr * sp * cy + sr * cp * sy,
            cr * cp * sy - sr * sp * cy,
            cr * cp * cy + sr * sp * sy,
    };
    const Quat basis{ kHalfSqrt2, 0.0, 0.0, kHalfSqrt2 };
    return normalized_quat(multiply(multiply(basis, frd), conjugate(basis)));
}

Vec3 shortest_attitude_error_frd(const Quat &actual_y_up, const Vec3 &target_angle_frd) {
    Quat error = normalized_quat(multiply(conjugate(normalized_quat(actual_y_up)), frd_attitude(target_angle_frd)));
    if (error.w < 0.0) {
        error = {-error.x, -error.y, -error.z, -error.w};
    }
    const double vector_norm = std::sqrt(error.x * error.x + error.y * error.y + error.z * error.z);
    const double scale = vector_norm > 1e-12 ? 2.0 * std::atan2(vector_norm, error.w) / vector_norm : 2.0;
    return y_up_to_frd({error.x * scale, error.y * scale, error.z * scale});
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

bool finite_vec3(const Vec3 &value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

bool finite_quat(const Quat &value) {
    return finite_vec3({value.x, value.y, value.z}) && std::isfinite(value.w) && quat_norm(value) > 0.0;
}

bool valid_state(const RigidBodyState &state) {
    if (!finite_vec3(state.position) || !finite_vec3(state.velocity) || !finite_quat(state.orientation) ||
            !finite_vec3(state.angular_velocity) || !finite_vec3(state.propwash_disturbance_rad_s2)) {
        return false;
    }
    return std::all_of(state.motor_thrust_newtons.begin(), state.motor_thrust_newtons.end(),
            [](double value) { return std::isfinite(value) && value >= 0.0; });
}

bool valid_clock(const SimulationClock &clock, const SimulationConfig &config) {
    if (!std::isfinite(clock.substep_accumulator) || clock.substep_accumulator < 0.0 ||
            clock.substep_accumulator >= 1.0) {
        return false;
    }
    const std::uint64_t maximum_frame_substeps =
            static_cast<std::uint64_t>(config.substep_hz / config.physics_hz) +
            (config.substep_hz % config.physics_hz == 0 ? 0U : 1U);
    return clock.total_substeps <= std::numeric_limits<std::uint64_t>::max() - maximum_frame_substeps;
}

bool valid_config(const SimulationConfig &config) {
    const double values[] = {
            config.seconds, config.mass_kg, config.gravity_mps2, config.total_thrust_newtons,
            config.max_total_thrust_newtons, config.hover_throttle, config.motor_tau_s,
            config.battery_nominal_voltage_v, config.battery_cells, config.battery_cell_resistance_ohm,
            config.battery_remaining_mah, config.max_total_current_a, config.max_motor_rpm,
            config.altitude_hold_noise_deadband_m, config.air_density_kg_m3,
            config.a4_ground_effect.kf, config.a4_ground_effect.ground_effect_coeff,
            config.a4_ground_effect.prop_radius_m, config.a4_ground_effect.height_clip_m,
            config.a5_downwash.prop_radius_m, config.a5_downwash.coeff_1, config.a5_downwash.coeff_2,
            config.a5_downwash.coeff_3, config.a6_propwash.full_collective_angular_accel_rad_s2,
            config.a6_propwash.minimum_wake_entry_speed_mps, config.a6_propwash.minimum_transverse_rate_rad_s,
    };
    return config.physics_hz > 0 && config.substep_hz >= config.physics_hz &&
            static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz) <= 1000000.0 &&
            std::all_of(std::begin(values), std::end(values), [](double value) { return std::isfinite(value); }) &&
            finite_vec3(config.external_force_world) && finite_vec3(config.wind_world_mps) &&
            finite_vec3(config.wind_turbulence_mps) && finite_vec3(config.a3_drag.coefficient) &&
            finite_vec3(config.body_drag.drag_coefficient) && finite_vec3(config.body_drag.frontal_area_m2) &&
            finite_vec3(config.body_drag.center_of_pressure_frd_m) &&
            std::all_of(config.a4_ground_effect.motor_rpm.begin(), config.a4_ground_effect.motor_rpm.end(),
                    [](double value) { return std::isfinite(value); }) &&
            config.mass_kg > 0.0 && config.gravity_mps2 > 0.0 && config.altitude_hold_noise_deadband_m >= 0.0 && config.air_density_kg_m3 > 0.0 &&
            config.hover_throttle >= 0.0 && config.hover_throttle <= 1.0 && config.motor_tau_s >= 0.0 &&
            valid_state(config.initial_state) && validate_per_motor_config(config.per_motor);
}

} // namespace

bool valid_flight_command(const FlightCommand &command) {
    return std::isfinite(command.throttle) && command.throttle >= 0.0 && command.throttle <= 1.0 &&
            std::isfinite(command.roll_degrees) && std::isfinite(command.pitch_degrees) &&
            std::isfinite(command.yaw_rate_degrees_per_second) &&
            std::isfinite(command.vertical_velocity_mps) && std::abs(command.vertical_velocity_mps) <= 3.0;
}

bool valid_acro_command(const AcroCommand &command) {
    return std::isfinite(command.throttle) && command.throttle >= 0.0 && command.throttle <= 1.0 &&
            std::isfinite(command.roll_stick) && std::isfinite(command.pitch_stick) && std::isfinite(command.yaw_stick) &&
            std::isfinite(command.rates.rc_rate) && command.rates.rc_rate >= 0.0 && command.rates.rc_rate <= 3.0 &&
            std::isfinite(command.rates.super_rate) && command.rates.super_rate >= 0.0 && command.rates.super_rate <= 1.0 &&
            std::isfinite(command.rates.expo) && command.rates.expo >= 0.0 && command.rates.expo <= 1.0;
}

double normalize_angle_radians(double angle) {
    return std::isfinite(angle) ? std::remainder(angle, 2.0 * 3.14159265358979323846) : 0.0;
}

const char *step_status_code(StepStatus status) {
    switch (status) {
        case StepStatus::Ok: return "Ok";
        case StepStatus::InvalidCommand: return "InvalidCommand";
        case StepStatus::InvalidConfig: return "InvalidConfig";
        case StepStatus::InvalidState: return "InvalidState";
        case StepStatus::InvalidControlOutput: return "InvalidControlOutput";
        case StepStatus::ResourceLimitExceeded: return "ResourceLimitExceeded";
    }
    return "InvalidControlOutput";
}

StepStatus validate_angle_step_inputs(
        const RigidBodyState &state,
        const SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        const Quat &estimated_attitude) {
    if (!valid_flight_command(command)) return StepStatus::InvalidCommand;
    if (!valid_config(config)) return StepStatus::InvalidConfig;
    return valid_state(state) && finite_quat(estimated_attitude) && valid_clock(clock, config)
            ? StepStatus::Ok : StepStatus::InvalidState;
}

StepStatus validate_acro_step_inputs(
        const RigidBodyState &state,
        const SimulationClock &clock,
        const SimulationConfig &config,
        const AcroCommand &command) {
    if (!valid_acro_command(command)) return StepStatus::InvalidCommand;
    if (!valid_config(config)) return StepStatus::InvalidConfig;
    return valid_state(state) && valid_clock(clock, config) ? StepStatus::Ok : StepStatus::InvalidState;
}

StepStatus validate_altitude_hold_step_inputs(
        const RigidBodyState &state,
        const SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        double measured_altitude_m,
        const Quat &estimated_attitude) {
    if (!valid_flight_command(command)) return StepStatus::InvalidCommand;
    if (!valid_config(config) || !std::isfinite(measured_altitude_m)) return StepStatus::InvalidConfig;
    return valid_state(state) && finite_quat(estimated_attitude) && valid_clock(clock, config)
            ? StepStatus::Ok : StepStatus::InvalidState;
}

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
    target_angle_frd_ = {};
    target_rate_frd_ = {};
    previous_rate_error_frd_ = {};
    filtered_rate_derivative_frd_ = {};
    mode_family_ = ModeFamily::None;
    control_initialized_ = false;
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
    target_angle_frd_ = {};
    target_rate_frd_ = {};
    previous_rate_error_frd_ = {};
    filtered_rate_derivative_frd_ = {};
    mode_family_ = ModeFamily::None;
    control_initialized_ = false;
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

FlightControlState FlightController::control_state() const {
    return {target_angle_frd_, target_rate_frd_, rate_integral_, previous_rate_error_frd_, filtered_rate_derivative_frd_,
            static_cast<int>(mode_family_), control_initialized_, altitude_hold_captured_, altitude_hold_just_captured_,
            altitude_hold_target_m_, motor_saturation_latched_, pid_saturation_latched_, motor_thrust_newtons_};
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
        ModeFamily mode_family,
        const Vec3 &desired_angles_frd,
        const Vec3 &desired_rates_frd,
        const Quat &estimated_attitude,
        double dt,
        std::array<double, 3> &pid_output,
        std::array<bool, 3> &pid_saturated) {
    MotorCommands commands;
    pid_saturated = {};
    if (!armed_) {
        mode_family_ = ModeFamily::None;
        control_initialized_ = false;
        return commands;
    }

    const Vec3 measured_angle = frd_euler(estimated_attitude);
    const Vec3 measured_rate = y_up_to_frd(state.angular_velocity);
    if (!control_initialized_ || mode_family_ != mode_family) {
        target_angle_frd_ = measured_angle;
        target_rate_frd_ = measured_rate;
        rate_integral_ = {};
        previous_rate_error_frd_ = {};
        filtered_rate_derivative_frd_ = {};
        mode_family_ = mode_family;
        control_initialized_ = true;
    }

    const double maximum_delta = kTargetRateAccelerationRadS2 * std::max(dt, 0.0);
    if (mode_family == ModeFamily::Angle) {
        double *target_angles[] = {&target_angle_frd_.x, &target_angle_frd_.y};
        double *target_rates[] = {&target_rate_frd_.x, &target_rate_frd_.y};
        const double desired_angles[] = {desired_angles_frd.x, desired_angles_frd.y};
        for (std::size_t index = 0; index < 2; ++index) {
            const double error = wrap_pi(desired_angles[index] - *target_angles[index]);
            const double rate_command = std::clamp(error / kAngleInputTimeConstantS, -kMaxRateRadS, kMaxRateRadS);
            const double next_rate = move_toward(*target_rates[index], rate_command, maximum_delta);
            const double next_angle = *target_angles[index] + next_rate * dt;
            if ((error > 0.0 && next_angle >= desired_angles[index]) ||
                    (error < 0.0 && next_angle <= desired_angles[index])) {
                *target_angles[index] = desired_angles[index];
                *target_rates[index] = 0.0;
            } else {
                *target_angles[index] = next_angle;
                *target_rates[index] = next_rate;
            }
        }
        target_rate_frd_.z = move_toward(
                target_rate_frd_.z,
                std::clamp(desired_rates_frd.z, -kMaxRateRadS, kMaxRateRadS),
                maximum_delta);
        target_angle_frd_.z = wrap_pi(target_angle_frd_.z + target_rate_frd_.z * dt);
    } else {
        target_rate_frd_.x = move_toward(target_rate_frd_.x, std::clamp(desired_rates_frd.x, -kMaxRateRadS, kMaxRateRadS), maximum_delta);
        target_rate_frd_.y = move_toward(target_rate_frd_.y, std::clamp(desired_rates_frd.y, -kMaxRateRadS, kMaxRateRadS), maximum_delta);
        target_rate_frd_.z = move_toward(target_rate_frd_.z, std::clamp(desired_rates_frd.z, -kMaxRateRadS, kMaxRateRadS), maximum_delta);
    }

    const Vec3 attitude_error = mode_family == ModeFamily::Angle
            ? shortest_attitude_error_frd(estimated_attitude, target_angle_frd_) : Vec3{};
    const Vec3 rate_setpoint{
            target_rate_frd_.x + attitude_error.x * kAngleP,
            target_rate_frd_.y + attitude_error.y * kAngleP,
            target_rate_frd_.z,
    };
    const std::array<double, 3> errors = {
            rate_setpoint.x - measured_rate.x,
            rate_setpoint.y - measured_rate.y,
            rate_setpoint.z - measured_rate.z,
    };
    std::array<double, 3> derivative{};
    std::array<double, 3> previous_error = {
            previous_rate_error_frd_.x,
            previous_rate_error_frd_.y,
            previous_rate_error_frd_.z,
    };
    std::array<double, 3> filtered_derivative = {
            filtered_rate_derivative_frd_.x,
            filtered_rate_derivative_frd_.y,
            filtered_rate_derivative_frd_.z,
    };
    const double derivative_alpha = alpha_from_tau(dt, kDerivativeFilterTimeConstantS);
    for (std::size_t index = 0; index < derivative.size(); ++index) {
        const double raw_derivative = dt > 0.0 ? (errors[index] - previous_error[index]) / dt : 0.0;
        filtered_derivative[index] += (raw_derivative - filtered_derivative[index]) * derivative_alpha;
        previous_error[index] = errors[index];
        derivative[index] = filtered_derivative[index];
    }
    previous_rate_error_frd_ = {previous_error[0], previous_error[1], previous_error[2]};
    filtered_rate_derivative_frd_ = {filtered_derivative[0], filtered_derivative[1], filtered_derivative[2]};
    auto torque_for = [&](const std::array<double, 3> &integral) {
        return Vec3{
                errors[0] * kRateP + target_rate_frd_.x * kRatePFeedForward + integral[0] + derivative[0] * kRateD,
                errors[1] * kRateP + target_rate_frd_.y * kRatePFeedForward + integral[1] + derivative[1] * kRateD,
                errors[2] * kRateP + target_rate_frd_.z * kRatePFeedForward + integral[2] + derivative[2] * kRateD,
        };
    };
    Vec3 target_torque_frd = torque_for(rate_integral_);
    QuadXMixerResult mixed = quad_x_mix_thrust(
            config,
            target_thrust_newtons(config, throttle),
            target_torque_frd);
    if (!mixed.valid) {
        commands.normalized.fill(std::numeric_limits<double>::quiet_NaN());
        return commands;
    }

    bool saturated = mixed.collective_saturated || mixed.axis_saturated[0] || mixed.axis_saturated[1] || mixed.axis_saturated[2];
    for (double command : mixed.normalized) {
        saturated = saturated || command <= 1.0e-12 || command >= 1.0 - 1.0e-12;
    }
    for (std::size_t index = 0; index < rate_integral_.size(); ++index) {
        const double candidate = std::clamp(
                rate_integral_[index] + errors[index] * kRateI * std::max(dt, 0.0),
                -kRateIntegralLimitNm,
                kRateIntegralLimitNm);
        if (!saturated || std::abs(candidate) <= std::abs(rate_integral_[index])) {
            rate_integral_[index] = candidate;
        }
    }
    target_torque_frd = torque_for(rate_integral_);
    mixed = quad_x_mix_thrust(config, target_thrust_newtons(config, throttle), target_torque_frd);
    if (!mixed.valid) {
        commands.normalized.fill(std::numeric_limits<double>::quiet_NaN());
        return commands;
    }
    const std::array<double, 3> target_torque = {target_torque_frd.x, target_torque_frd.y, target_torque_frd.z};
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
    pid_output = {target_torque[1], target_torque[2], target_torque[0]};
    pid_saturated = {pid_saturated[1], pid_saturated[2], pid_saturated[0]};
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
    const bool px4_external = mode == "PX4_ACTUATOR";
    snapshot.timestamp_us = static_cast<std::uint64_t>(std::llround(sample_time_s * 1000000.0));
    snapshot.publish_count = telemetry_publish_count_ + 1;
    snapshot.control_authority = px4_external ? "px4_external" : "flight_controller";
    snapshot.armed_available = !px4_external;
    snapshot.pid_available = !px4_external;
    snapshot.armed = !px4_external && armed_;
    snapshot.mode = mode;

    const bool actuator_state_available = armed_ || px4_external;
    const double throttle_clamped = actuator_state_available ? std::clamp(throttle, 0.0, 1.0) : 0.0;
    std::array<double, 4> motor_speeds{};
    for (std::size_t index = 0; index < snapshot.motors.size(); ++index) {
        MotorTelemetry &motor = snapshot.motors[index];
        motor.thrust_newtons = actuator_state_available ? sample.state.motor_thrust_newtons[index] : 0.0;
        const double thrust_fraction = config.per_motor.max_thrust_per_motor_newtons > 0.0
                ? std::clamp(motor.thrust_newtons / config.per_motor.max_thrust_per_motor_newtons, 0.0, 1.0)
                : 0.0;
        motor.current_a = actuator_state_available ? config.per_motor.max_current_per_motor_a * thrust_fraction : 0.0;
        motor_speeds[index] = motor_speed_rad_s_from_thrust(
                motor.thrust_newtons,
                config.per_motor.max_thrust_per_motor_newtons,
                config.max_motor_rpm);
        motor.speed_rad_s = motor_speeds[index];
        motor.saturated = actuator_state_available && ((!px4_external && motor_saturation_latched_[index]) || throttle_clamped >= 1.0 - 1e-9 ||
                (config.per_motor.max_thrust_per_motor_newtons > 0.0 &&
                        motor.thrust_newtons >= config.per_motor.max_thrust_per_motor_newtons - 1e-9));
    }

    snapshot.ground_effect_gain = a4_ground_effect_lift_newtons(config.a4_ground_effect, sample.state.position.y);
    snapshot.wind_world_mps = y_up_to_frd(config.wind_world_mps);
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
    snapshot.air_density_kg_m3 = sample.air_density_kg_m3;
    snapshot.airspeed_body_frd_mps_mean = sample.airspeed_body_frd_mps_mean;
    snapshot.a3_drag_force_body_frd_n_mean = sample.a3_drag_force_body_frd_n_mean;
    snapshot.a6_angular_accel_body_frd_rad_s2 = y_up_to_frd(sample.propwash_disturbance_rad_s2);
    snapshot.config_hash = config.config_hash;
    if (!config.body_drag.enabled) {
        snapshot.body_drag_force_body_frd_n_mean = {};
        snapshot.body_drag_torque_body_frd_nm_mean = {};
        snapshot.body_drag_operating_state = "disabled";
        snapshot.body_drag_evidence_state = "provisional";
        snapshot.body_drag_reason_code = "disabled";
    } else if (!validate_body_drag_config(config.body_drag, config.air_density_kg_m3)) {
        snapshot.body_drag_force_body_frd_n_mean = {NAN, NAN, NAN};
        snapshot.body_drag_torque_body_frd_nm_mean = {NAN, NAN, NAN};
        snapshot.body_drag_operating_state = "out_of_domain";
        snapshot.body_drag_evidence_state = "unavailable";
        snapshot.body_drag_reason_code = "invalid_configuration";
    } else if (sample.body_drag_force_applied && sample.body_drag_torque_applied) {
        snapshot.body_drag_force_body_frd_n_mean = sample.body_drag_force_body_frd_n_mean;
        snapshot.body_drag_torque_body_frd_nm_mean = sample.body_drag_torque_body_frd_nm_mean;
        snapshot.body_drag_operating_state = "active";
        snapshot.body_drag_evidence_state = "provisional";
        snapshot.body_drag_reason_code = "active_provisional";
    } else if (sample.body_drag_force_applied || sample.body_drag_torque_applied) {
        snapshot.body_drag_force_body_frd_n_mean = sample.body_drag_force_applied
                ? sample.body_drag_force_body_frd_n_mean : Vec3{NAN, NAN, NAN};
        snapshot.body_drag_torque_body_frd_nm_mean = sample.body_drag_torque_applied
                ? sample.body_drag_torque_body_frd_nm_mean : Vec3{NAN, NAN, NAN};
        snapshot.body_drag_operating_state = "out_of_domain";
        snapshot.body_drag_evidence_state = "unavailable";
        snapshot.body_drag_reason_code = sample.body_drag_force_applied
                ? "torque_unavailable" : "force_unavailable";
    } else {
        snapshot.body_drag_force_body_frd_n_mean = {NAN, NAN, NAN};
        snapshot.body_drag_torque_body_frd_nm_mean = {NAN, NAN, NAN};
        snapshot.body_drag_operating_state = "unavailable";
        snapshot.body_drag_evidence_state = "unavailable";
        snapshot.body_drag_reason_code = "authority_unavailable";
    }
    snapshot.a3_operating_state = config.a3_drag.enabled ? "active" : "disabled";
    snapshot.a6_operating_state = config.a6_propwash.enabled ? "active" : "disabled";
    snapshot.battery.voltage_v = loaded_voltage_v(config, throttle_clamped);
    snapshot.battery.sag_v = std::max(0.0, config.battery_nominal_voltage_v - snapshot.battery.voltage_v);
    snapshot.battery.remaining_mah = config.battery_remaining_mah;
    for (std::size_t index = 0; index < snapshot.pid.size(); ++index) {
        snapshot.pid[index].output = px4_external ? NAN : pid_output[index];
        const std::size_t frd_index = (index + 1) % snapshot.pid.size();
        snapshot.pid[index].saturated = !px4_external && (pid_saturated[index] || pid_saturation_latched_[frd_index]);
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

void FlightController::publish_unavailable_telemetry(
        const TrajectorySample &sample,
        const SimulationConfig &config,
        const std::string &mode) {
    TrajectorySample unavailable = sample;
    unavailable.body_drag_force_applied = false;
    unavailable.body_drag_torque_applied = false;
    maybe_publish_telemetry(unavailable, config, 0.0, {0.0, 0.0, 0.0}, {false, false, false}, mode);
}

void FlightController::publish_applied_telemetry(
        const TrajectorySample &sample,
        const SimulationConfig &config,
        double throttle,
        const std::string &mode) {
    maybe_publish_telemetry(sample, config, throttle, {0.0, 0.0, 0.0}, {false, false, false}, mode);
}

TrajectorySample FlightController::step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command) {
    return try_step_angle_mode(state, clock, config, command, state.orientation).sample;
}

TrajectorySample FlightController::step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        const Quat &estimated_attitude) {
    return try_step_angle_mode(state, clock, config, command, estimated_attitude).sample;
}

StepResult FlightController::try_step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        const Quat &estimated_attitude) {
    const StepStatus input_status = validate_angle_step_inputs(state, clock, config, command, estimated_attitude);
    if (input_status != StepStatus::Ok) {
        return {input_status, {}};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    FlightController staged_controller = *this;
    const TrajectorySample sample = staged_controller.step_angle_mode_impl(
            staged_state, staged_clock, config, command, estimated_attitude);
    if (sample.substeps == 0 || !valid_state(staged_state) || !std::isfinite(sample.time_seconds)) {
        return {StepStatus::InvalidControlOutput, {}};
    }
    state = staged_state;
    clock = staged_clock;
    *this = std::move(staged_controller);
    return {StepStatus::Ok, sample};
}

TrajectorySample FlightController::step_angle_mode_impl(
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
    const Vec3 desired_angles_frd{
            radians(command.roll_degrees),
            radians(command.pitch_degrees),
            0.0,
    };
    const Vec3 desired_rates_frd{0.0, 0.0, radians(command.yaw_rate_degrees_per_second)};
    const TrajectorySample sample = step_per_motor_physics_frame(state, clock, frame_config, [&](double dt) {
        const MotorCommands commands_for_substep = control_substep(
                state,
                frame_config,
                throttle,
                ModeFamily::Angle,
                desired_angles_frd,
                desired_rates_frd,
                estimated_attitude,
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
    return try_step_acro_mode(state, clock, config, command).sample;
}

StepResult FlightController::try_step_acro_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const AcroCommand &command) {
    const StepStatus input_status = validate_acro_step_inputs(state, clock, config, command);
    if (input_status != StepStatus::Ok) {
        return {input_status, {}};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    FlightController staged_controller = *this;
    const TrajectorySample sample = staged_controller.step_acro_mode_impl(staged_state, staged_clock, config, command);
    if (sample.substeps == 0 || !valid_state(staged_state) || !std::isfinite(sample.time_seconds)) {
        return {StepStatus::InvalidControlOutput, {}};
    }
    state = staged_state;
    clock = staged_clock;
    *this = std::move(staged_controller);
    return {StepStatus::Ok, sample};
}

TrajectorySample FlightController::step_acro_mode_impl(
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
    const Vec3 desired_rates_frd{
            radians(betaflight_rate_degrees_per_second(command.roll_stick, command.rates)),
            radians(betaflight_rate_degrees_per_second(command.pitch_stick, command.rates)),
            radians(betaflight_rate_degrees_per_second(command.yaw_stick, command.rates)),
    };
    const TrajectorySample sample = step_per_motor_physics_frame(state, clock, frame_config, [&](double dt) {
        const MotorCommands commands_for_substep = control_substep(
                state,
                frame_config,
                throttle,
                ModeFamily::Acro,
                {},
                desired_rates_frd,
                state.orientation,
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
    return try_step_altitude_hold_mode(
            state, clock, config, command, measured_altitude_m, estimated_attitude).sample;
}

StepResult FlightController::try_step_altitude_hold_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        double measured_altitude_m,
        const Quat &estimated_attitude) {
    const StepStatus input_status = validate_altitude_hold_step_inputs(
            state, clock, config, command, measured_altitude_m, estimated_attitude);
    if (input_status != StepStatus::Ok) {
        return {input_status, {}};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    FlightController staged_controller = *this;
    const TrajectorySample sample = staged_controller.step_altitude_hold_mode_impl(
            staged_state, staged_clock, config, command, measured_altitude_m, estimated_attitude);
    if (sample.substeps == 0 || !valid_state(staged_state) || !std::isfinite(sample.time_seconds)) {
        return {StepStatus::InvalidControlOutput, {}};
    }
    state = staged_state;
    clock = staged_clock;
    *this = std::move(staged_controller);
    return {StepStatus::Ok, sample};
}

TrajectorySample FlightController::step_altitude_hold_mode_impl(
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
        altitude_hold_target_m_ += command.vertical_velocity_mps * control_dt;
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
        const bool inside_noise_band = std::abs(altitude_error_m) <= frame_config.altitude_hold_noise_deadband_m;
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
    const Vec3 desired_angles_frd{
            radians(command.roll_degrees),
            radians(command.pitch_degrees),
            0.0,
    };
    const Vec3 desired_rates_frd{0.0, 0.0, radians(command.yaw_rate_degrees_per_second)};
    const TrajectorySample sample = step_per_motor_physics_frame(state, clock, frame_config, [&](double dt) {
        const MotorCommands commands_for_substep = control_substep(
                state,
                frame_config,
                target_throttle,
                ModeFamily::Angle,
                desired_angles_frd,
                desired_rates_frd,
                estimated_attitude,
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
    target_angle_frd_ = {};
    target_rate_frd_ = {};
    previous_rate_error_frd_ = {};
    filtered_rate_derivative_frd_ = {};
    mode_family_ = ModeFamily::None;
    control_initialized_ = false;
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
