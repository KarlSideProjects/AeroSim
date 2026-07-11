#include "aerosim_simulation.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

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
    if (!near(y_up.x, 2.0, 1e-12) || !near(y_up.y, 4.0, 1e-12) || !near(y_up.z, 3.0, 1e-12)) {
        return fail("FRD (forward, right, down) must cross the named boundary to Y-up (x, z, -y)");
    }
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

    aerosim::MotorCommands left_commands{{0.0, 0.0, 1.0, 1.0}};
    aerosim::RigidBodyState left_state;
    aerosim::SimulationClock left_clock;
    aerosim::step_per_motor_physics_frame(left_state, left_clock, config, left_commands);
    if (left_state.angular_velocity.x >= 0.0) {
        return fail("left-side Quad-X motor differential must create negative roll in the documented Y-up convention");
    }

    aerosim::MotorCommands front_commands{{0.0, 1.0, 0.0, 1.0}};
    aerosim::RigidBodyState front_state;
    aerosim::SimulationClock front_clock;
    aerosim::step_per_motor_physics_frame(front_state, front_clock, config, front_commands);
    if (front_state.angular_velocity.z <= 0.0) {
        return fail("front-side Quad-X motor differential must create positive pitch in the documented Y-up convention");
    }
    aerosim::MotorCommands yaw_commands{{0.0, 1.0, 1.0, 0.0}};
    aerosim::RigidBodyState yaw_state;
    aerosim::SimulationClock yaw_clock;
    aerosim::step_per_motor_physics_frame(yaw_state, yaw_clock, config, yaw_commands);
    if (yaw_state.angular_velocity.y <= 0.0) {
        return fail("opposite-spin motor pair must create positive reaction-torque yaw");
    }

    aerosim::MotorCommands invalid_commands{{0.0, std::numeric_limits<double>::quiet_NaN(), 0.0, 0.0}};
    aerosim::RigidBodyState invalid_state;
    aerosim::SimulationClock invalid_clock;
    const aerosim::TrajectorySample rejected = aerosim::step_per_motor_physics_frame(
            invalid_state, invalid_clock, config, invalid_commands);
    if (rejected.substeps != 0 || invalid_clock.total_substeps != 0) {
        return fail("per-motor core must reject non-finite external commands without advancing state");
    }

    return EXIT_SUCCESS;
}
