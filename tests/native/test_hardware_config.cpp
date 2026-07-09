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

} // namespace

int main() {
    const double mass_kg = 0.68;
    aerosim::HardwareConfig hardware;
    if (!hardware.set_mass_kg(mass_kg)) {
        return fail("hardware config must accept a positive mass");
    }

    aerosim::SimulationConfig config = hardware.simulation_config();
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

    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        controller.step_angle_mode(angle_state, angle_clock, config, hover);
    }

    if (!std::isfinite(angle_state.position.y) || !near(angle_state.position.y, 0.0, 1e-9)) {
        return fail("Angle Mode hover must calculate thrust from configured mass");
    }

    return EXIT_SUCCESS;
}
