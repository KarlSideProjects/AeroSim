#include "aerosim_aerodynamics.hpp"
#include "aerosim_simulation.hpp"

#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

aerosim::SimulationConfig config() {
    aerosim::SimulationConfig result;
    result.physics_hz = 10;
    result.substep_hz = 1000;
    result.mass_kg = 0.72;
    result.gravity_mps2 = 9.80665;
    result.per_motor.inertia_kg_m2 = {0.01, 0.01, 0.02};
    result.per_motor.max_thrust_per_motor_newtons = 10.0;
    result.per_motor.max_current_per_motor_a = 1.0;
    result.per_motor.yaw_torque_per_newton = 0.01;
    result.per_motor.position_frd = {{
            {-0.10, 0.10, 0.0},
            {0.10, 0.10, 0.0},
            {-0.10, -0.10, 0.0},
            {0.10, -0.10, 0.0},
    }};
    result.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    result.a5_downwash = {true, 2.31348e-2, 2267.18, 0.16, -0.11};
    return result;
}

} // namespace

int main() {
    auto enabled = config();
    auto disabled = enabled;
    disabled.a5_downwash.enabled = false;
    const aerosim::Vec3 upper{-0.1, 2.0, 0.0};
    const aerosim::MotorCommands hover{{0.1765, 0.1765, 0.1765, 0.1765}};

    std::int32_t calls = 0;
    enabled.external_force_provider = [&](const aerosim::Vec3 &target) {
        ++calls;
        return aerosim::Vec3{0.0, aerosim::a5_downwash_force_y_newtons(enabled.a5_downwash, upper, target), 0.0};
    };
    aerosim::RigidBodyState enabled_state;
    aerosim::SimulationClock enabled_clock;
    aerosim::step_per_motor_physics_frame(enabled_state, enabled_clock, enabled, hover);
    if (calls != 100) {
        return fail("named A5 downwash must be evaluated for every physics substep");
    }

    aerosim::RigidBodyState disabled_state;
    aerosim::SimulationClock disabled_clock;
    const auto disabled_sample = aerosim::step_per_motor_physics_frame(disabled_state, disabled_clock, disabled, hover);
    if (disabled_sample.state.position.y <= enabled_state.position.y) {
        return fail("A5 effects-off must remove the integrated downwash loss");
    }
    return EXIT_SUCCESS;
}
