#include "aerosim_probe.hpp"
#include "aerosim_simulation.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool orientation_stays_unit(std::int32_t physics_hz, std::int32_t substep_hz, std::uint64_t expected_substeps) {
    aerosim::SimulationConfig config;
    config.seconds = 600.0;
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.initial_state.angular_velocity = {0.25, -0.5, 0.75};

    const auto samples = aerosim::simulate_trajectory(config);
    if (samples.empty() || samples.back().substeps != expected_substeps) {
        return false;
    }
    return std::isfinite(samples.back().state.orientation.x) &&
            std::isfinite(samples.back().state.orientation.y) &&
            std::isfinite(samples.back().state.orientation.z) &&
            std::isfinite(samples.back().state.orientation.w) &&
            near(aerosim::quat_norm(samples.back().state.orientation), 1.0, 1e-6);
}

} // namespace

int main() {
    if (aerosim::probe_value() != 47) {
        return fail("probe value changed");
    }

    aerosim::SimulationConfig hover;
    hover.seconds = 600.0;
    hover.physics_hz = 240;
    hover.substep_hz = 1000;
    hover.total_thrust_newtons = hover.mass_kg * hover.gravity_mps2;

    const auto hover_samples = aerosim::simulate_trajectory(hover);
    if (hover_samples.empty()) {
        return fail("hover simulation produced no samples");
    }

    const auto &hover_final = hover_samples.back();
    if (hover_final.substeps != 600000) {
        return fail("1000 Hz substep scheduler did not run exactly 600000 substeps over 10 minutes");
    }
    if (!near(aerosim::quat_norm(hover_final.state.orientation), 1.0, 1e-6)) {
        return fail("quaternion norm drift exceeded G0.3 threshold");
    }
    if (!std::isfinite(hover_final.state.position.y) || !near(hover_final.state.position.y, 0.0, 1e-9)) {
        return fail("hover trajectory should remain stationary with thrust equal to weight");
    }

    if (!orientation_stays_unit(240, 1000, 600000)) {
        return fail("1000 Hz orientation integration failed G0.3 drift/finite check");
    }
    if (!orientation_stays_unit(120, 500, 300000)) {
        return fail("500 Hz mobile orientation integration failed G0.3 drift/finite check");
    }

    const aerosim::Quat enormous_quaternion{
            1.0e200, -1.0e200, 1.0e200, -1.0e200};
    if (!near(aerosim::quat_norm(enormous_quaternion), 2.0e200, 1.0e185)) {
        return fail("quaternion norm must remain finite for scale-safe finite inputs");
    }

    aerosim::RigidBodyState invalid_timing_state;
    const aerosim::RigidBodyState invalid_timing_before = invalid_timing_state;
    aerosim::SimulationClock invalid_timing_clock;
    invalid_timing_clock.substep_accumulator = INFINITY;
    const aerosim::TrajectorySample invalid_timing = aerosim::step_physics_frame(
            invalid_timing_state, invalid_timing_clock, hover);
    if (invalid_timing.substeps != 0 || invalid_timing_state.position.x != invalid_timing_before.position.x ||
            !std::isinf(invalid_timing_clock.substep_accumulator)) {
        return fail("invalid simulation timing must be rejected before scheduling divisions");
    }

    aerosim::SimulationConfig unschedulable_timing = hover;
    unschedulable_timing.physics_hz = 1000;
    unschedulable_timing.substep_hz = 999;
    aerosim::RigidBodyState unschedulable_state;
    aerosim::SimulationClock unschedulable_clock;
    if (aerosim::step_physics_frame(unschedulable_state, unschedulable_clock, unschedulable_timing).substeps != 0 ||
            unschedulable_clock.substep_accumulator != 0.0) {
        return fail("physics frames without a control substep must be rejected transactionally");
    }

    aerosim::SimulationConfig freefall;
    freefall.seconds = 60.0;
    freefall.physics_hz = 240;
    freefall.substep_hz = 1000;
    const auto freefall_samples = aerosim::simulate_trajectory(freefall);
    const double expected_y = -0.5 * freefall.gravity_mps2 * freefall.seconds * freefall.seconds;
    if (freefall_samples.empty() || !near(freefall_samples.back().state.position.y, expected_y, 0.4)) {
        return fail("freefall trajectory diverged from analytic solution beyond integrator tolerance");
    }

    return EXIT_SUCCESS;
}
