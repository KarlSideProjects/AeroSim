#pragma once

#include <cstdint>
#include <vector>

namespace aerosim {

struct Vec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

struct Quat {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
    double w = 1.0;
};

struct RigidBodyState {
    Vec3 position;
    Vec3 velocity;
    Quat orientation;
    Vec3 angular_velocity;
};

struct SimulationConfig {
    double seconds = 1.0;
    std::int32_t physics_hz = 240;
    std::int32_t substep_hz = 1000;
    double mass_kg = 1.0;
    double gravity_mps2 = 9.80665;
    double total_thrust_newtons = 0.0;
    RigidBodyState initial_state;
};

struct SimulationClock {
    double substep_accumulator = 0.0;
    std::uint64_t total_substeps = 0;
};

struct TrajectorySample {
    double time_seconds = 0.0;
    RigidBodyState state;
    std::uint64_t substeps = 0;
};

double quat_norm(const Quat &q);
TrajectorySample step_physics_frame(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config);
std::vector<TrajectorySample> simulate_trajectory(const SimulationConfig &config);

} // namespace aerosim
