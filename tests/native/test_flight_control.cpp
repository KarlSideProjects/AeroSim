#include "aerosim_flight_control.hpp"

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

double roll_degrees(const aerosim::Quat &q) {
    return 2.0 * std::atan2(q.z, q.w) * 180.0 / kPi;
}

double pitch_degrees(const aerosim::Quat &q) {
    return 2.0 * std::atan2(q.x, q.w) * 180.0 / kPi;
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
    for (int frame = 0; frame < config.physics_hz / 2; ++frame) {
        acro_sample = acro_controller.step_acro_mode(acro_state, acro_clock, config, acro_roll);
    }
    const double roll_rate_degrees_per_second = acro_sample.state.angular_velocity.z * 180.0 / kPi;
    if (!near(roll_rate_degrees_per_second, 720.0, 720.0 * 0.05)) {
        return fail("G2.5 Acro full-stick roll must reach 720 degrees per second within 5%");
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

    return EXIT_SUCCESS;
}
