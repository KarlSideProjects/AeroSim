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

void configure_power_model(aerosim::SimulationConfig &config) {
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = config.mass_kg * config.gravity_mps2 * 2.0;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.battery_cell_resistance_ohm = 0.0;
    config.max_total_current_a = 1.0;
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
