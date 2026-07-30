#include "aerosim_imu.hpp"
#include "aerosim_simulation.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

bool near(double actual, double expected, double tolerance = 1e-9) {
    return std::abs(actual - expected) <= tolerance;
}

int fail(const char *message) {
    std::cerr << message << '\n';
    return EXIT_FAILURE;
}

aerosim::ImuSimulator ideal_imu(double gravity_mps2) {
    aerosim::ImuConfig config;
    config.gravity_mps2 = gravity_mps2;
    config.sample_hz = 1000.0;
    return aerosim::ImuSimulator(config);
}

aerosim::SimulationConfig frame_config(double gravity_mps2, double total_thrust_newtons) {
    aerosim::SimulationConfig config;
    config.mass_kg = 1.0;
    config.gravity_mps2 = gravity_mps2;
    config.total_thrust_newtons = total_thrust_newtons;
    config.physics_hz = 1000;
    config.substep_hz = 1000;
    return config;
}

} // namespace

int main() {
    constexpr double kGravityMps2 = 9.81;

    aerosim::RigidBodyState resting_state;
    const aerosim::ImuSample resting = ideal_imu(kGravityMps2).sample(resting_state);
    if (!near(resting.accel_mps2.x, 0.0) || !near(resting.accel_mps2.y, kGravityMps2) || !near(resting.accel_mps2.z, 0.0)) {
        return fail("stationary body must report upward specific force equal to gravity");
    }

    aerosim::RigidBodyState freefall_state;
    aerosim::SimulationClock freefall_clock;
    if (aerosim::step_physics_frame(
                freefall_state, freefall_clock, frame_config(kGravityMps2, 0.0)).substeps != 1) {
        return fail("freefall test frame did not integrate");
    }
    const aerosim::ImuSample freefall = ideal_imu(kGravityMps2).sample(freefall_state);
    if (!near(freefall.accel_mps2.x, 0.0) || !near(freefall.accel_mps2.y, 0.0) || !near(freefall.accel_mps2.z, 0.0)) {
        return fail("freefall must report zero specific force");
    }

    constexpr double kUpwardAccelerationMps2 = 3.0;
    aerosim::RigidBodyState ascending_state;
    aerosim::SimulationClock ascending_clock;
    if (aerosim::step_physics_frame(
                ascending_state,
                ascending_clock,
                frame_config(kGravityMps2, kGravityMps2 + kUpwardAccelerationMps2)).substeps != 1) {
        return fail("ascending test frame did not integrate");
    }
    const aerosim::ImuSample ascending = ideal_imu(kGravityMps2).sample(ascending_state);
    if (!near(ascending.accel_mps2.x, 0.0) ||
            !near(ascending.accel_mps2.y, kGravityMps2 + kUpwardAccelerationMps2) ||
            !near(ascending.accel_mps2.z, 0.0)) {
        return fail("upward acceleration must add to upward body specific force");
    }

    return EXIT_SUCCESS;
}
