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
    const aerosim::Vec3 frd{2.0, -3.0, 4.0};
    const aerosim::Vec3 y_up = aerosim::frd_to_y_up(frd);
    const aerosim::Vec3 round_trip = aerosim::y_up_to_frd(y_up);
    if (!near(round_trip.x, frd.x, 1e-12) ||
            !near(round_trip.y, frd.y, 1e-12) ||
            !near(round_trip.z, frd.z, 1e-12)) {
        return fail("FRD to Y-up bridge transform must round-trip exactly");
    }

    aerosim::SimulationConfig config;
    config.gravity_mps2 = 0.0;
    config.physics_hz = 100;
    config.substep_hz = 100;
    config.mass_kg = 1.0;
    config.per_motor.inertia_kg_m2 = {0.01, 0.01, 0.02};
    config.per_motor.max_thrust_per_motor_newtons = 1.0;
    config.per_motor.max_current_per_motor_a = 1.0;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.10, 0.10, 0.0},
            {0.10, 0.10, 0.0},
            {-0.10, -0.10, 0.0},
            {0.10, -0.10, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};

    aerosim::MotorCommands equal_commands{{1.0, 1.0, 1.0, 1.0}};
    aerosim::RigidBodyState equal_state;
    aerosim::SimulationClock equal_clock;
    aerosim::step_per_motor_physics_frame(equal_state, equal_clock, config, equal_commands);
    if (!near(equal_state.angular_velocity.x, 0.0, 1e-12) ||
            !near(equal_state.angular_velocity.y, 0.0, 1e-12) ||
            !near(equal_state.angular_velocity.z, 0.0, 1e-12)) {
        return fail("equal Quad-X motor commands must cancel roll, pitch, and yaw torque");
    }

    aerosim::MotorCommands right_commands{{1.0, 1.0, 0.0, 0.0}};
    aerosim::RigidBodyState right_state;
    aerosim::SimulationClock right_clock;
    aerosim::step_per_motor_physics_frame(right_state, right_clock, config, right_commands);
    if (right_state.angular_velocity.x <= 0.0) {
        return fail("right-side Quad-X motor differential must create a positive FRD roll torque in Y-up physics");
    }

    return EXIT_SUCCESS;
}
