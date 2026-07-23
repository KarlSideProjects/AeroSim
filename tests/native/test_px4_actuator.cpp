#include "aerosim_simulation.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

aerosim::SimulationConfig config() {
    aerosim::SimulationConfig value;
    value.physics_hz = 240;
    value.substep_hz = 1000;
    value.mass_kg = 1.0;
    value.motor_tau_s = 0.0;
    value.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    value.per_motor.max_thrust_per_motor_newtons = 16.2;
    value.per_motor.max_current_per_motor_a = 27.0;
    value.per_motor.yaw_torque_per_newton = 0.01;
    value.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    value.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    return value;
}

} // namespace

int main() {
    const aerosim::SimulationConfig physics_config = config();
    aerosim::RigidBodyState state;
    aerosim::SimulationClock clock;
    const aerosim::MotorCommands commands{{0.5, 0.5, 0.5, 0.5}};
    const aerosim::TrajectorySample sample = aerosim::step_per_motor_physics_frame(
            state, clock, physics_config, commands);
    if (sample.substeps != 4 || sample.first_substeps != 1 ||
            sample.first_substep_time_seconds != 0.001 ||
            !std::isfinite(sample.state.position.y) || sample.state.position.y <= 0.0) {
        return fail("PX4 actuator commands must use the deterministic per-motor physics path");
    }

    const aerosim::RigidBodyState before_invalid = state;
    const aerosim::SimulationClock clock_before_invalid = clock;
    const aerosim::MotorCommands invalid{{0.5, 1.1, 0.5, 0.5}};
    const aerosim::TrajectorySample rejected = aerosim::step_per_motor_physics_frame(
            state, clock, physics_config, invalid);
    if (rejected.substeps != 0 || state.position.y != before_invalid.position.y ||
            clock.total_substeps != clock_before_invalid.total_substeps) {
        return fail("invalid PX4 actuator output must be rejected without mutating simulation state");
    }

    aerosim::SimulationConfig overflowing_force_config = physics_config;
    overflowing_force_config.mass_kg = 0.5;
    overflowing_force_config.external_force_world.x = 1.0e308;
    const aerosim::RigidBodyState before_overflow = state;
    const aerosim::SimulationClock clock_before_overflow = clock;
    const aerosim::TrajectorySample overflow_rejected = aerosim::step_per_motor_physics_frame(
            state, clock, overflowing_force_config, commands);
    if (overflow_rejected.substeps != 0 || !std::isfinite(state.position.x) ||
            state.position.x != before_overflow.position.x ||
            clock.total_substeps != clock_before_overflow.total_substeps) {
        return fail("overflowing PX4 control force must roll back simulation state");
    }
    return EXIT_SUCCESS;
}
