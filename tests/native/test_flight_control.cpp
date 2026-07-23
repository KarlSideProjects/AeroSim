#include "aerosim_flight_control.hpp"
#include "aerosim_aerodynamics.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

constexpr double kPi = 3.14159265358979323846;

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

double vector_length(const aerosim::Vec3 &value) {
    return std::sqrt(value.x * value.x + value.y * value.y + value.z * value.z);
}

double pearson(const std::array<double, 5> &x, const std::array<double, 5> &y) {
    double mean_x = 0.0;
    double mean_y = 0.0;
    for (std::size_t index = 0; index < x.size(); ++index) {
        mean_x += x[index];
        mean_y += y[index];
    }
    mean_x /= static_cast<double>(x.size());
    mean_y /= static_cast<double>(x.size());
    double covariance = 0.0;
    double variance_x = 0.0;
    double variance_y = 0.0;
    for (std::size_t index = 0; index < x.size(); ++index) {
        const double dx = x[index] - mean_x;
        const double dy = y[index] - mean_y;
        covariance += dx * dy;
        variance_x += dx * dx;
        variance_y += dy * dy;
    }
    return covariance / std::sqrt(variance_x * variance_y);
}

double roll_degrees(const aerosim::Quat &q) {
    return 2.0 * std::atan2(q.x, q.w) * 180.0 / kPi;
}

double pitch_degrees(const aerosim::Quat &q) {
    return 2.0 * std::atan2(q.z, q.w) * 180.0 / kPi;
}

void configure_power_model(aerosim::SimulationConfig &config) {
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = 64.8;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.battery_cell_resistance_ohm = 0.0;
    config.max_total_current_a = 108.0;
    config.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    config.per_motor.max_thrust_per_motor_newtons = 16.2;
    config.per_motor.max_current_per_motor_a = 27.0;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
}

} // namespace

int main() {
    aerosim::FlightController blocked_controller;
    if (blocked_controller.arm(0.25)) {
        return fail("arm must be rejected unless throttle is low");
    }

    if (blocked_controller.armed()) {
        return fail("rejected arm attempt must leave the controller disarmed");
    }
    if (blocked_controller.arm_reject_code() != "throttle_not_low") {
        return fail("high-throttle arm rejection must be observable");
    }

    aerosim::FlightCommand climb;
    climb.throttle = 0.75;

    aerosim::SimulationConfig config;
    config.seconds = 1.0;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

    aerosim::RigidBodyState disarmed_state;
    aerosim::SimulationClock disarmed_clock;
    aerosim::FlightController disarmed_controller;
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        disarmed_controller.step_angle_mode(disarmed_state, disarmed_clock, config, climb);
    }

    aerosim::RigidBodyState armed_state;
    aerosim::SimulationClock armed_clock;
    aerosim::FlightController armed_controller;
    if (!armed_controller.arm(0.0)) {
        return fail("low throttle should satisfy the arm precondition");
    }
    armed_controller.disarm();
    if (armed_controller.armed()) {
        return fail("disarm should clear the flight controller armed state");
    }
    if (!armed_controller.arm(0.0)) {
        return fail("flight controller should re-arm after disarm");
    }
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        armed_controller.step_angle_mode(armed_state, armed_clock, config, climb);
    }

    if (!std::isfinite(armed_state.position.y) || armed_state.position.y <= disarmed_state.position.y + 1.0) {
        return fail("throttle should produce lift only after a low-throttle arm");
    }

    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    hover.roll_degrees = 0.0;
    hover.pitch_degrees = 0.0;

    aerosim::RigidBodyState disarm_state;
    aerosim::SimulationClock disarm_clock;
    aerosim::FlightController disarm_controller;
    aerosim::SimulationConfig disarm_config = config;
    disarm_config.motor_tau_s = 0.03;
    if (!disarm_controller.arm(0.0)) {
        return fail("disarm state setup should arm from low throttle");
    }
    for (int frame = 0; frame < 30; ++frame) {
        disarm_controller.step_angle_mode(disarm_state, disarm_clock, disarm_config, hover);
    }
    disarm_controller.disarm();
    if (disarm_controller.motor_thrust_newtons() != 0.0 || disarm_controller.telemetry_snapshot().armed) {
        return fail("disarm must immediately clear controller diagnostics and telemetry armed state");
    }
    for (const aerosim::MotorTelemetry &motor : disarm_controller.telemetry_snapshot().motors) {
        if (motor.thrust_newtons != 0.0 || motor.speed_rad_s != 0.0 || motor.current_a != 0.0) {
            return fail("disarm must immediately clear telemetry motor state");
        }
    }
    for (int frame = 0; frame < 10; ++frame) {
        disarm_controller.step_angle_mode(disarm_state, disarm_clock, disarm_config, hover);
    }
    for (double thrust : disarm_state.motor_thrust_newtons) {
        if (thrust != 0.0) {
            return fail("disarm must clear live motor thrust before the next physics step");
        }
    }
    for (const aerosim::MotorTelemetry &motor : disarm_controller.telemetry_snapshot().motors) {
        if (motor.thrust_newtons != 0.0 || motor.speed_rad_s != 0.0 || motor.current_a != 0.0) {
            return fail("disarmed telemetry must match cleared live motor state");
        }
    }

    aerosim::RigidBodyState altitude_disarm_state;
    aerosim::SimulationClock altitude_disarm_clock;
    aerosim::FlightController altitude_disarm_controller;
    aerosim::FlightCommand disarmed_hold_command;
    disarmed_hold_command.throttle = 0.9;
    altitude_disarm_controller.step_altitude_hold_mode(
            altitude_disarm_state,
            altitude_disarm_clock,
            config,
            disarmed_hold_command,
            100.0,
            aerosim::Quat{});
    if (altitude_disarm_controller.pid_timing_stats().samples != 0 ||
            altitude_disarm_controller.telemetry_snapshot().pid[1].saturated) {
        return fail("disarmed altitude hold must not publish PID timing or collective saturation");
    }
    altitude_disarm_controller.capture_altitude_hold(100.0);
    if (!altitude_disarm_controller.arm(0.0)) {
        return fail("altitude hold must re-arm after disarmed cache setup");
    }
    aerosim::FlightCommand rearm_hold_command;
    rearm_hold_command.throttle = 0.1;
    for (int frame = 0; frame < 120; ++frame) {
        altitude_disarm_controller.step_altitude_hold_mode(
                altitude_disarm_state,
                altitude_disarm_clock,
                config,
                rearm_hold_command,
                0.0,
                aerosim::Quat{});
    }
    altitude_disarm_controller.step_altitude_hold_mode(
            altitude_disarm_state,
            altitude_disarm_clock,
            config,
            rearm_hold_command,
            0.0,
            aerosim::Quat{});
    if (altitude_disarm_controller.motor_thrust_newtons() > config.max_total_thrust_newtons * 0.2) {
        return fail("disarmed altitude hold must not repopulate stale trim before re-arm");
    }

    aerosim::RigidBodyState tilted_state;
    const double ten_degrees = 10.0 * kPi / 180.0;
    tilted_state.orientation.x = std::sin(ten_degrees * 0.5);
    tilted_state.orientation.w = std::cos(ten_degrees * 0.5);

    aerosim::SimulationClock tilted_clock;
    aerosim::FlightController angle_controller;
    if (!angle_controller.arm(0.0)) {
        return fail("angle mode setup should arm from low throttle");
    }
    for (int frame = 0; frame < config.physics_hz * 2; ++frame) {
        angle_controller.step_angle_mode(tilted_state, tilted_clock, config, hover);
    }

    if (!near(tilted_state.orientation.x, 0.0, 0.02) || std::abs(tilted_state.velocity.y) > 1.0) {
        return fail("Angle Mode hover should level attitude without requiring Position Hold");
    }

    aerosim::RigidBodyState altitude_hold_state;
    aerosim::SimulationClock altitude_hold_clock;
    aerosim::FlightController altitude_hold_controller;
    if (!altitude_hold_controller.arm(0.0)) {
        return fail("Altitude Hold setup should arm from low throttle");
    }
    const double hold_altitude_m = 3.0;
    double angle_mode_thrust = 0.0;
    double altitude_hold_entry_thrust = 0.0;
    double altitude_hold_exit_thrust = 0.0;
    altitude_hold_state.position.y = hold_altitude_m;
    altitude_hold_controller.step_angle_mode(altitude_hold_state, altitude_hold_clock, config, hover, aerosim::Quat{});
    angle_mode_thrust = altitude_hold_controller.motor_thrust_newtons();
    altitude_hold_controller.capture_altitude_hold(hold_altitude_m);
    double max_altitude_hold_drift_m = 0.0;
    for (int frame = 0; frame < config.physics_hz * 60; ++frame) {
        const double noise_phase = static_cast<double>(frame) / static_cast<double>(config.physics_hz);
        const double noisy_barometer_m = hold_altitude_m +
                0.10 * std::sin(noise_phase * 11.0) +
                0.05 * std::sin(noise_phase * 37.0);
        altitude_hold_controller.step_altitude_hold_mode(
                altitude_hold_state,
                altitude_hold_clock,
                config,
                hover,
                noisy_barometer_m,
                aerosim::Quat{});
        if (frame == 0) {
            altitude_hold_entry_thrust = altitude_hold_controller.motor_thrust_newtons();
        }
        max_altitude_hold_drift_m = std::max(
                max_altitude_hold_drift_m,
                std::abs(altitude_hold_state.position.y - hold_altitude_m));
    }
    altitude_hold_controller.step_angle_mode(altitude_hold_state, altitude_hold_clock, config, hover, aerosim::Quat{});
    altitude_hold_exit_thrust = altitude_hold_controller.motor_thrust_newtons();
    if (max_altitude_hold_drift_m > 0.15) {
        return fail("G2.6 Altitude Hold must keep 60 second altitude drift within +/-15 cm with barometer noise");
    }
    if (std::abs(altitude_hold_entry_thrust - angle_mode_thrust) > config.mass_kg * config.gravity_mps2 * 0.05 ||
            std::abs(altitude_hold_exit_thrust - altitude_hold_entry_thrust) > config.mass_kg * config.gravity_mps2 * 0.05) {
        return fail("Altitude Hold mode transitions must not introduce a thrust step");
    }

    aerosim::RigidBodyState hold_state;
    aerosim::SimulationClock hold_clock;
    aerosim::FlightController hold_controller;
    if (!hold_controller.arm(0.0)) {
        return fail("Angle Mode hold setup should arm from low throttle");
    }
    for (int frame = 0; frame < config.physics_hz * 60; ++frame) {
        hold_controller.step_angle_mode(hold_state, hold_clock, config, hover);
    }
    if (std::abs(roll_degrees(hold_state.orientation)) > 1.0 ||
            std::abs(pitch_degrees(hold_state.orientation)) > 1.0) {
        return fail("G2.3 Angle Mode zero-command attitude drift must stay within 1 degree over 60 seconds");
    }

    for (const int profile_hz : {1000, 500}) {
        aerosim::SimulationConfig timing_config = config;
        timing_config.substep_hz = profile_hz;
        aerosim::RigidBodyState timing_state;
        aerosim::SimulationClock timing_clock;
        aerosim::FlightController timing_controller;
        if (!timing_controller.arm(0.0)) {
            return fail("PID timing setup should arm from low throttle");
        }
        aerosim::TrajectorySample timing_sample;
        for (int frame = 0; frame < timing_config.physics_hz * 60; ++frame) {
            timing_sample = timing_controller.step_angle_mode(timing_state, timing_clock, timing_config, hover);
            const aerosim::PidTimingStats &timing = timing_controller.pid_timing_stats();
            if (timing.target_hz != static_cast<double>(profile_hz) ||
                    timing.samples == 0 ||
                    timing.p99_jitter_fraction > 0.10) {
                return fail("G2.1 PID loop P99 jitter must stay within +/-10% of the profile rate");
            }
        }
        const auto expected_substeps = static_cast<std::uint64_t>(profile_hz * 60);
        if (timing_sample.substeps != expected_substeps ||
                !near(timing_sample.time_seconds, 60.0, 1.0 / static_cast<double>(profile_hz))) {
            return fail("G2.1 PID loop must execute the profile substep rate without accumulated drift over 60 seconds");
        }
    }

    const aerosim::RateProfile freestyle_rates{1.15, 0.72, 0.25};
    const struct {
        double stick;
        double betaflight_degrees_per_second;
    } rate_points[] = {
            {-1.00, -821.428571428571},
            {-0.75, -320.800781250000},
            {-0.50, -140.380859375000},
            {-0.25, -52.865377286585},
            {0.00, 0.000000000000},
            {0.25, 52.865377286585},
            {0.50, 140.380859375000},
            {0.75, 320.800781250000},
            {1.00, 821.428571428571},
    };
    for (const auto &point : rate_points) {
        const double actual = aerosim::betaflight_rate_degrees_per_second(point.stick, freestyle_rates);
        const double tolerance = std::max(0.01, std::abs(point.betaflight_degrees_per_second) * 0.01);
        if (!near(actual, point.betaflight_degrees_per_second, tolerance)) {
            return fail("G2.5 rates curve must match Betaflight RC Rate / Super Rate / Expo points within 1%");
        }
    }
    for (double target : {-500.0, -120.0, 0.0, 120.0, 500.0}) {
        const double stick = aerosim::betaflight_stick_for_rate_degrees_per_second(target, freestyle_rates);
        const double round_trip = aerosim::betaflight_rate_degrees_per_second(stick, freestyle_rates);
        if (!near(round_trip, target, 0.01)) {
            return fail("Betaflight rate inverse did not round-trip");
        }
    }

    aerosim::RigidBodyState acro_state;
    aerosim::SimulationClock acro_clock;
    aerosim::FlightController acro_controller;
    if (!acro_controller.arm(0.0)) {
        return fail("Acro setup should arm from low throttle");
    }
    aerosim::AcroCommand acro_roll;
    acro_roll.throttle = 0.5;
    acro_roll.roll_stick = 1.0;
    acro_roll.rates = {1.0, 0.722222222222, 0.0};
    aerosim::TrajectorySample acro_sample;
    bool reached_acro_band = false;
    double acro_reach_time_s = 0.0;
    double acro_band_start_s = 0.0;
    double acro_max_degrees_per_second = 0.0;
    for (int frame = 0; frame < config.physics_hz / 2; ++frame) {
        acro_sample = acro_controller.step_acro_mode(acro_state, acro_clock, config, acro_roll);
        const double rate = acro_sample.state.angular_velocity.x * 180.0 / kPi;
        acro_max_degrees_per_second = std::max(acro_max_degrees_per_second, rate);
        if (!reached_acro_band && near(rate, 720.0, 720.0 * 0.05)) {
            reached_acro_band = true;
            acro_reach_time_s = acro_sample.time_seconds;
            acro_band_start_s = acro_sample.time_seconds;
        }
        if (reached_acro_band && acro_sample.time_seconds <= acro_band_start_s + 0.050 &&
                !near(rate, 720.0, 720.0 * 0.05)) {
            return fail("G2.5 Acro full-stick roll must hold the 720 degree per second band for 50 ms");
        }
    }
    const double roll_rate_degrees_per_second = acro_sample.state.angular_velocity.x * 180.0 / kPi;
    if (!reached_acro_band || acro_reach_time_s > 0.250 ||
            !near(roll_rate_degrees_per_second, 720.0, 720.0 * 0.05) ||
            acro_max_degrees_per_second > 720.0 * 1.05) {
        return fail("G2.5 Acro full-stick roll must reach and retain 720 degrees per second without exceeding its upper band");
    }

    aerosim::RigidBodyState roll_step_state;
    aerosim::SimulationClock roll_step_clock;
    aerosim::FlightController roll_step_controller;
    if (!roll_step_controller.arm(0.0)) {
        return fail("Angle Mode step setup should arm from low throttle");
    }
    aerosim::FlightCommand roll_step;
    roll_step.throttle = 0.5;
    roll_step.roll_degrees = 30.0;
    bool reached_90_percent = false;
    double rise_time_s = 0.0;
    double max_roll_degrees = 0.0;
    double last_outside_2_percent_s = 0.0;
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        const aerosim::TrajectorySample sample =
                roll_step_controller.step_angle_mode(roll_step_state, roll_step_clock, config, roll_step);
        const double roll = roll_degrees(sample.state.orientation);
        max_roll_degrees = std::max(max_roll_degrees, roll);
        if (!reached_90_percent && roll >= 27.0) {
            reached_90_percent = true;
            rise_time_s = sample.time_seconds;
        }
        if (!near(roll, 30.0, 0.6)) {
            last_outside_2_percent_s = sample.time_seconds;
        }
    }
    if (!reached_90_percent || rise_time_s > 0.150) {
        return fail("G2.4 Angle Mode 30 degree roll step rise time must be <= 150 ms");
    }
    if (max_roll_degrees > 33.0) {
        return fail("G2.4 Angle Mode 30 degree roll step overshoot must be <= 10%");
    }
    if (last_outside_2_percent_s > 0.500) {
        return fail("G2.4 Angle Mode 30 degree roll step must settle within 2% by 500 ms");
    }

    tilted_state.position = {1.0, 2.0, 3.0};
    tilted_state.velocity = {4.0, 5.0, 6.0};
    tilted_state.angular_velocity = {7.0, 8.0, 9.0};
    angle_controller.reset_flight(tilted_state, tilted_clock);
    if (!angle_controller.armed()) {
        return fail("reset must keep armed so throttle follows the controller immediately");
    }
    if (!near(tilted_state.position.x, 0.0, 0.0) ||
            !near(tilted_state.position.y, 0.0, 0.0) ||
            !near(tilted_state.position.z, 0.0, 0.0) ||
            !near(tilted_state.velocity.x, 0.0, 0.0) ||
            !near(tilted_state.velocity.y, 0.0, 0.0) ||
            !near(tilted_state.velocity.z, 0.0, 0.0) ||
            !near(tilted_state.angular_velocity.x, 0.0, 0.0) ||
            !near(tilted_state.angular_velocity.y, 0.0, 0.0) ||
            !near(tilted_state.angular_velocity.z, 0.0, 0.0) ||
            tilted_clock.total_substeps != 0) {
        return fail("reset must clear flight state and substep clock");
    }

    aerosim::A6PropwashConfig propwash;
    propwash.enabled = true;
    propwash.full_collective_angular_accel_rad_s2 = 12.0;
    propwash.minimum_wake_entry_speed_mps = 2.0;
    propwash.minimum_transverse_rate_rad_s = 0.5;
    aerosim::SimulationConfig propwash_config = config;
    propwash_config.a6_propwash = propwash;
    aerosim::RigidBodyState split_s_state;
    const double split_s_angle = 60.0 * kPi / 180.0;
    split_s_state.orientation.x = std::sin(split_s_angle * 0.5);
    split_s_state.orientation.w = std::cos(split_s_angle * 0.5);
    split_s_state.velocity.y = -6.0;
    split_s_state.angular_velocity = aerosim::frd_to_y_up({3.0, 4.0, 0.0});
    aerosim::SimulationClock split_s_clock;
    aerosim::FlightController split_s_controller;
    if (!split_s_controller.arm(0.0)) {
        return fail("A6 split-S setup must arm from low throttle");
    }
    aerosim::FlightCommand split_s_command;
    split_s_command.throttle = 0.75;
    const aerosim::TrajectorySample split_s_sample = split_s_controller.step_angle_mode(
            split_s_state, split_s_clock, propwash_config, split_s_command);
    if (vector_length(split_s_sample.state.propwash_disturbance_rad_s2) <= 0.0 ||
            vector_length(split_s_controller.telemetry_snapshot().propwash_disturbance_rad_s2) <= 0.0) {
        return fail("G3.6 A6 split-S exit must inject and publish a non-zero propwash disturbance");
    }
    split_s_controller.clear_propwash_telemetry();
    if (vector_length(split_s_controller.telemetry_snapshot().propwash_disturbance_rad_s2) != 0.0) {
        return fail("A6 disable transition must clear the published propwash disturbance immediately");
    }

    std::array<double, 5> throttle_values = {0.2, 0.4, 0.6, 0.8, 1.0};
    std::array<double, 5> disturbance_values{};
    for (std::size_t index = 0; index < throttle_values.size(); ++index) {
        disturbance_values[index] = vector_length(aerosim::a6_propwash_angular_acceleration_rad_s2(
                propwash,
                split_s_state,
                split_s_state.velocity,
                throttle_values[index]));
    }
    if (pearson(throttle_values, disturbance_values) < 0.8) {
        return fail("G3.6 A6 disturbance magnitude must correlate with throttle at >= 0.8");
    }
    aerosim::RigidBodyState no_descent_state = split_s_state;
    no_descent_state.velocity = {};
    if (vector_length(aerosim::a6_propwash_angular_acceleration_rad_s2(
                propwash,
                no_descent_state,
                no_descent_state.velocity,
                1.0)) != 0.0) {
        return fail("A6 must stay zero without relative wake-entry speed");
    }
    aerosim::RigidBodyState no_transverse_rate_state = split_s_state;
    no_transverse_rate_state.angular_velocity = {};
    if (vector_length(aerosim::a6_propwash_angular_acceleration_rad_s2(
                propwash,
                no_transverse_rate_state,
                no_transverse_rate_state.velocity,
                1.0)) != 0.0) {
        return fail("A6 must stay zero without transverse attitude-change rate");
    }

    aerosim::SimulationConfig propwash_disabled_config = propwash_config;
    propwash_disabled_config.a6_propwash.enabled = false;
    aerosim::RigidBodyState disabled_propwash_state = split_s_state;
    aerosim::SimulationClock disabled_propwash_clock;
    aerosim::FlightController disabled_propwash_controller;
    if (!disabled_propwash_controller.arm(0.0)) {
        return fail("A6 disabled setup must arm from low throttle");
    }
    const aerosim::TrajectorySample disabled_propwash_sample = disabled_propwash_controller.step_angle_mode(
            disabled_propwash_state, disabled_propwash_clock, propwash_disabled_config, split_s_command);
    if (vector_length(disabled_propwash_sample.state.propwash_disturbance_rad_s2) != 0.0 ||
            vector_length(disabled_propwash_controller.telemetry_snapshot().propwash_disturbance_rad_s2) != 0.0) {
        return fail("G3.6 A6 disabled mode must produce exact-zero disturbance and telemetry");
    }

    return EXIT_SUCCESS;
}
