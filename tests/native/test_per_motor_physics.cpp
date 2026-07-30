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

    const auto columns = aerosim::quad_x_mixer_columns(config.per_motor);
    if (!near(columns[1][0], -0.10, 1e-12) || !near(columns[2][0], -0.10, 1e-12) ||
            !near(columns[3][0], 0.01, 1e-12)) {
        return fail("Quad-X mixer columns must expose the canonical motor torque basis");
    }

    // PX4 10016_none_iris allocation, mapped by motor name to AeroSim's stable
    // [rear_right, front_right, rear_left, front_left] order.  The Iris is not a
    // square frame: the right arms intentionally differ fore/aft.
    auto iris = config.per_motor;
    iris.position_frd = {{
            {-0.1515, 0.1875, 0.0},
            {0.1515, 0.2450, 0.0},
            {-0.1515, -0.1875, 0.0},
            {0.1515, -0.2450, 0.0},
    }};
    iris.spin_direction = {{-1.0, 1.0, 1.0, -1.0}};
    iris.yaw_torque_per_newton = 0.05;
    if (!aerosim::validate_per_motor_config(iris)) {
        return fail("the named PX4 Iris asymmetric Quad-X allocation must be accepted");
    }
    const auto iris_columns = aerosim::quad_x_mixer_columns(iris);
    const std::array<std::array<double, 4>, 4> expected_iris_columns = {{
            {{1.0, 1.0, 1.0, 1.0}},
            {{-0.1875, -0.2450, 0.1875, 0.2450}},
            {{-0.1515, 0.1515, -0.1515, 0.1515}},
            {{-0.05, 0.05, 0.05, -0.05}},
    }};
    for (std::size_t axis = 0; axis < iris_columns.size(); ++axis) {
        for (std::size_t motor = 0; motor < iris_columns[axis].size(); ++motor) {
            if (!near(iris_columns[axis][motor], expected_iris_columns[axis][motor], 1e-12)) {
                return fail("each named PX4 Iris allocation coefficient must match the source contract");
            }
        }
    }

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
    if (right_state.angular_velocity.x >= 0.0) {
        return fail("right-side Quad-X motor differential must create the frozen negative roll torque in Y-up physics");
    }

    config.substep_hz = 200;
    aerosim::RigidBodyState rollback_state;
    rollback_state.position.x = 3.0;
    aerosim::SimulationClock rollback_clock;
    const aerosim::RigidBodyState initial_state = rollback_state;
    const aerosim::SimulationClock initial_clock = rollback_clock;
    int callback_count = 0;
    const aerosim::TrajectorySample rollback_sample = aerosim::step_per_motor_physics_frame(
            rollback_state,
            rollback_clock,
            config,
            [&callback_count](double) {
                ++callback_count;
                if (callback_count == 1) {
                    return aerosim::MotorCommands{{1.0, 1.0, 1.0, 1.0}};
                }
                const double invalid = std::numeric_limits<double>::quiet_NaN();
                return aerosim::MotorCommands{{invalid, invalid, invalid, invalid}};
            });
    if (rollback_sample.substeps != 0 || rollback_state.position.x != initial_state.position.x ||
            rollback_state.motor_thrust_newtons != initial_state.motor_thrust_newtons ||
            rollback_clock.total_substeps != initial_clock.total_substeps ||
            rollback_clock.substep_accumulator != initial_clock.substep_accumulator) {
        return fail("invalid per-motor substep commands must roll back the complete frame");
    }

    return EXIT_SUCCESS;
}
