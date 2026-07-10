#include "aerosim_flight_control.hpp"
#include "aerosim_simulation.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

} // namespace

int main() {
    const double mass_kg = 0.68;
    aerosim::HardwareConfig hardware;
    if (!hardware.set_mass_kg(mass_kg)) {
        return fail("hardware config must accept a positive mass");
    }

    aerosim::SimulationConfig config = hardware.simulation_config();
    config.seconds = 1.0;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    config.total_thrust_newtons = mass_kg * config.gravity_mps2;

    const auto samples = aerosim::simulate_trajectory(config);
    if (samples.empty()) {
        return fail("hardware-configured hover must produce trajectory rows");
    }

    const double final_y = samples.back().state.position.y;
    if (!std::isfinite(final_y) || !near(final_y, 0.0, 1e-9)) {
        return fail("native hover must use configured mass instead of the default 1 kg");
    }

    aerosim::RigidBodyState angle_state;
    aerosim::SimulationClock angle_clock;
    aerosim::FlightController controller;
    if (!controller.arm(0.0)) {
        return fail("angle mode hardware config test must arm from low throttle");
    }

    if (!hardware.set_power_model(mass_kg * config.gravity_mps2 * 4.0, 0.50, 0.0, 22.2, 6.0, 0.0, 1.0)) {
        return fail("hardware config must accept a no-sag hover power model");
    }
    config = hardware.simulation_config();
    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        controller.step_angle_mode(angle_state, angle_clock, config, hover);
    }

    if (!std::isfinite(angle_state.position.y) || !near(angle_state.position.y, 0.0, 1e-9)) {
        return fail("Angle Mode hover must calculate thrust from configured mass");
    }

    if (!hardware.set_power_model(mass_kg * config.gravity_mps2 * 4.0, 0.30, 0.0, 22.2, 6.0, 0.0, 1.0)) {
        return fail("hardware config must accept a derived motor power model");
    }
    config = hardware.simulation_config();
    angle_state = {};
    angle_clock = {};
    aerosim::FlightController derived_controller;
    if (!derived_controller.arm(0.0)) {
        return fail("derived power model test must arm from low throttle");
    }
    hover.throttle = 0.30;
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        derived_controller.step_angle_mode(angle_state, angle_clock, config, hover);
    }
    if (!std::isfinite(angle_state.position.y) || !near(angle_state.position.y, 0.0, 1e-9)) {
        return fail("Angle Mode hover must use derived hover throttle instead of a hardcoded 0.5");
    }

    const double unsagged_max_thrust = mass_kg * config.gravity_mps2 * 4.0;
    if (!hardware.set_power_model(unsagged_max_thrust, 0.25, 0.030, 22.2, 6.0, 0.003, 108.0)) {
        return fail("hardware config must accept a motor time constant");
    }
    config = hardware.simulation_config();
    const double sagged_cap = aerosim::available_thrust_cap_newtons(config, 1.0);
    if (!(sagged_cap < unsagged_max_thrust && sagged_cap > mass_kg * config.gravity_mps2)) {
        return fail("battery sag must reduce the real-time available thrust cap without preventing hover");
    }
    config.max_total_thrust_newtons = 0.0;
    if (aerosim::available_thrust_cap_newtons(config, 1.0) != 0.0) {
        return fail("available thrust cap must not fall back to mass/gravity/hover_throttle");
    }
    const double target_thrust = mass_kg * config.gravity_mps2;
    const double one_tau_thrust = aerosim::first_order_motor_response(
            0.0,
            target_thrust,
            config.motor_tau_s,
            config.motor_tau_s);
    if (!near(one_tau_thrust, target_thrust * (1.0 - std::exp(-1.0)), 1e-12)) {
        return fail("motor thrust must follow the configured first-order time constant analytically");
    }

    aerosim::PerMotorPhysicsConfig per_motor;
    per_motor.inertia_kg_m2 = {0.0030, 0.0030, 0.0050};
    per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    per_motor.max_thrust_per_motor_newtons = unsagged_max_thrust / 4.0;
    per_motor.max_current_per_motor_a = 27.0;
    per_motor.yaw_torque_per_newton = 0.01;
    if (!hardware.set_per_motor_model(per_motor)) {
        return fail("hardware config must accept a complete Quad-X per-motor model");
    }
    config = hardware.simulation_config();
    if (!near(config.per_motor.inertia_kg_m2.z, per_motor.inertia_kg_m2.z, 1e-12) ||
            !near(config.per_motor.position_frd[0].y, per_motor.position_frd[0].y, 1e-12) ||
            !near(config.per_motor.spin_direction[1], -1.0, 1e-12) ||
            !near(config.per_motor.max_thrust_per_motor_newtons, per_motor.max_thrust_per_motor_newtons, 1e-12)) {
        return fail("hardware config must preserve the preset-driven per-motor physics model");
    }

    return EXIT_SUCCESS;
}
