#include "aerosim_flight_control.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool same_vec3(const aerosim::Vec3 &actual, const aerosim::Vec3 &expected) {
    return actual.x == expected.x && actual.y == expected.y && actual.z == expected.z;
}

double maximum_pid_output(const aerosim::TelemetrySnapshot &snapshot) {
    return std::max({
            std::abs(snapshot.pid[0].output),
            std::abs(snapshot.pid[1].output),
            std::abs(snapshot.pid[2].output),
    });
}

aerosim::SimulationConfig standard_config() {
    aerosim::SimulationConfig config;
    config.mass_kg = 0.72;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    config.hover_throttle = 0.30;
    config.max_total_thrust_newtons = 64.8;
    config.motor_tau_s = 0.030;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.max_total_current_a = 108.0;
    config.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    config.per_motor.max_thrust_per_motor_newtons = 16.2;
    config.per_motor.max_current_per_motor_a = 27.0;
    config.per_motor.yaw_torque_per_newton = 0.1575 / 16.2;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    return config;
}

} // namespace

int main() {
    const aerosim::SimulationConfig config = standard_config();
    if (!same_vec3(aerosim::frd_to_y_up({2.0, -3.0, 4.0}), {2.0, -4.0, -3.0}) ||
            !same_vec3(aerosim::y_up_to_frd({2.0, -4.0, -3.0}), {2.0, -3.0, 4.0})) {
        return fail("FRD control values must cross the one named Y-up boundary exactly once");
    }

    const aerosim::QuadXMixerResult positive_roll = aerosim::quad_x_mix_thrust(config, 19.62, {0.2, 0.0, 0.0});
    if (!positive_roll.valid ||
            !(positive_roll.normalized[2] > positive_roll.normalized[0] &&
                    positive_roll.normalized[3] > positive_roll.normalized[1])) {
        return fail("positive FRD roll torque must raise the left motor pair and lower the right pair");
    }

    aerosim::RigidBodyState state;
    aerosim::SimulationClock clock;
    aerosim::FlightController controller;
    if (!controller.arm(0.0)) {
        return fail("cascade controller must arm from low throttle");
    }

    aerosim::FlightCommand command;
    command.throttle = 0.30;
    command.roll_degrees = 30.0;
    controller.step_angle_mode(state, clock, config, command);

    double thrust_sum = 0.0;
    bool differential = false;
    for (std::size_t index = 0; index < state.motor_thrust_newtons.size(); ++index) {
        const double thrust = state.motor_thrust_newtons[index];
        if (!std::isfinite(thrust) || thrust < 0.0) {
            return fail("cascaded controller must produce finite non-negative motor thrust");
        }
        thrust_sum += thrust;
        if (index > 0 && std::abs(thrust - state.motor_thrust_newtons[0]) > 1e-9) {
            differential = true;
        }
    }
    if (thrust_sum <= 0.0 || !differential) {
        return fail("non-zero Angle command must reach the per-motor mixer with differential thrust");
    }
    if (state.angular_velocity.x <= 0.0) {
        return fail("positive roll command must produce the positive FRD roll plant response");
    }

    aerosim::RigidBodyState coupled_state;
    coupled_state.orientation = {0.2392983377447303, -0.03813457647485015, 0.189307857412, 0.9515485246437885};
    aerosim::SimulationClock coupled_clock;
    aerosim::FlightController coupled_controller;
    if (!coupled_controller.arm(0.0)) {
        return fail("coupled quaternion fixture must arm from low throttle");
    }
    aerosim::FlightCommand coupled_command;
    coupled_command.throttle = 0.30;
    coupled_command.roll_degrees = 30.0;
    coupled_command.pitch_degrees = 20.0;
    coupled_controller.step_angle_mode(
            coupled_state, coupled_clock, config, coupled_command, coupled_state.orientation);
    if (maximum_pid_output(coupled_controller.telemetry_snapshot()) > 1e-4) {
        return fail("the coupled 30/20/10 degree quaternion fixture must have a zero Angle rate setpoint");
    }

    aerosim::RigidBodyState transition_state;
    aerosim::SimulationClock transition_clock;
    aerosim::FlightController transition_controller;
    if (!transition_controller.arm(0.0)) {
        return fail("Acro-to-Angle reset fixture must arm from low throttle");
    }
    aerosim::AcroCommand acro_command;
    acro_command.throttle = 0.30;
    acro_command.roll_stick = 1.0;
    acro_command.rates = {1.0, 0.722222222222, 0.0};
    for (int frame = 0; frame < 120; ++frame) {
        transition_controller.step_acro_mode(transition_state, transition_clock, config, acro_command);
    }
    aerosim::FlightCommand matching_angle;
    matching_angle.throttle = 0.30;
    matching_angle.roll_degrees = 2.0 * std::atan2(transition_state.orientation.x, transition_state.orientation.w) * 180.0 / 3.14159265358979323846;
    transition_controller.step_angle_mode(
            transition_state, transition_clock, config, matching_angle, transition_state.orientation);
    if (std::abs(transition_controller.telemetry_snapshot().pid[2].output) > 0.2) {
        return fail("Acro-to-Angle transition must clear the stale roll-rate command");
    }

    for (int frame = 0; frame < 120; ++frame) {
        transition_controller.step_angle_mode(
                transition_state, transition_clock, config, matching_angle, transition_state.orientation);
    }
    aerosim::AcroCommand neutral_acro;
    neutral_acro.throttle = 0.30;
    transition_controller.step_acro_mode(transition_state, transition_clock, config, neutral_acro);
    if (std::abs(transition_controller.telemetry_snapshot().pid[2].output) > 0.2) {
        return fail("Angle-to-Acro transition must clear the stale roll-angle shaper state");
    }

    aerosim::RigidBodyState saturated_state;
    aerosim::SimulationClock saturated_clock;
    aerosim::FlightController saturated_controller;
    if (!saturated_controller.arm(0.0)) {
        return fail("anti-windup fixture must arm from low throttle");
    }
    aerosim::FlightCommand saturated_command;
    saturated_command.throttle = 1.0;
    saturated_command.roll_degrees = 90.0;
    for (int frame = 0; frame < 30; ++frame) {
        saturated_controller.step_angle_mode(saturated_state, saturated_clock, config, saturated_command);
    }
    const double saturated_roll_output = std::abs(saturated_controller.telemetry_snapshot().pid[2].output);
    aerosim::FlightCommand release_command;
    release_command.throttle = 0.5;
    release_command.roll_degrees = 2.0 * std::atan2(saturated_state.orientation.x, saturated_state.orientation.w) *
            180.0 / 3.14159265358979323846;
    for (int frame = 0; frame < 240; ++frame) {
        saturated_controller.step_angle_mode(saturated_state, saturated_clock, config, release_command);
    }
    if (std::abs(saturated_controller.telemetry_snapshot().pid[2].output) >= saturated_roll_output) {
        return fail("motor-clamp anti-windup must unwind the roll PID after saturated error release");
    }
    return EXIT_SUCCESS;
}
