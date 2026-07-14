#include "aerosim_flight_control.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
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
    if (std::abs(state.angular_velocity.z) <= 1e-9) {
        return fail("controller command must produce a plant-derived angular response");
    }
    return EXIT_SUCCESS;
}
