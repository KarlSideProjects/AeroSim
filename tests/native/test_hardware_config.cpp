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

void configure_per_motor_model(aerosim::HardwareConfig &hardware) {
    aerosim::PerMotorPhysicsConfig model;
    model.inertia_kg_m2 = {0.003, 0.003, 0.005};
    model.max_thrust_per_motor_newtons = 10.0;
    model.max_current_per_motor_a = 1.0;
    model.yaw_torque_per_newton = 0.01;
    model.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    model.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    hardware.set_per_motor_model(model);
}

} // namespace

int main() {
    const double mass_kg = 0.68;
    aerosim::HardwareConfig hardware;
    if (!hardware.set_mass_kg(mass_kg)) {
        return fail("hardware config must accept a positive mass");
    }
    configure_per_motor_model(hardware);
    if (hardware.set_a3_drag_model(true, {NAN, 1.0e-4, 1.0e-4}) ||
            hardware.set_a3_drag_model(true, {-1.0e-4, 1.0e-4, 1.0e-4}) ||
            !hardware.set_a3_drag_model(true, {1.0e-4, 1.0e-4, 1.2e-4})) {
        return fail("hardware config must reject invalid A3 coefficients and preserve valid static settings");
    }
    aerosim::A6PropwashConfig a6;
    a6.enabled = true;
    a6.full_collective_angular_accel_rad_s2 = 12.0;
    a6.minimum_wake_entry_speed_mps = 2.0;
    a6.minimum_transverse_rate_rad_s = 0.5;
    if (!hardware.set_a6_propwash_model(true, a6)) {
        return fail("hardware config must accept a calibrated A6 propwash model");
    }
    aerosim::A6PropwashConfig invalid_a6 = a6;
    invalid_a6.minimum_transverse_rate_rad_s = -1.0;
    if (hardware.set_a6_propwash_model(true, invalid_a6)) {
        return fail("hardware config must reject negative A6 angular acceleration gain");
    }

    aerosim::SimulationConfig config = hardware.simulation_config();
    if (!config.a3_drag.enabled || !near(config.a3_drag.coefficient.x, 1.0e-4, 1e-12) ||
            !near(config.a3_drag.coefficient.z, 1.2e-4, 1e-12)) {
        return fail("hardware config must carry static A3 settings into every simulation config");
    }
    if (!config.a6_propwash.enabled || !near(config.a6_propwash.full_collective_angular_accel_rad_s2, 12.0, 1e-12) ||
            !near(config.a6_propwash.minimum_transverse_rate_rad_s, 0.5, 1e-12)) {
        return fail("hardware config must carry static A6 settings into every simulation config");
    }
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

    return EXIT_SUCCESS;
}
