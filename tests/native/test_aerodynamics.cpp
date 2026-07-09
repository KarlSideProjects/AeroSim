#include "aerosim_aerodynamics.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>

namespace {

constexpr double kPi = 3.14159265358979323846;

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

bool write_oracle_cases(const char *path) {
    if (path == nullptr || path[0] == '\0') {
        return true;
    }

    std::ofstream out(path);
    if (!out) {
        return false;
    }

    out << std::setprecision(17)
        << "case,coeff_x,coeff_y,coeff_z,rpm_0,rpm_1,rpm_2,rpm_3,qx,qy,qz,qw,vx,vy,vz,force_x,force_y,force_z\n";

    const aerosim::A3DragConfig configs[] = {
            {true, {1.0e-6, 1.0e-6, 1.2e-6}, {4000.0, 5000.0, 6000.0, 7000.0}},
            {true, {1.4e-6, 0.9e-6, 1.8e-6}, {8200.0, 8100.0, 8300.0, 8050.0}},
            {true, {0.8e-6, 1.1e-6, 1.5e-6}, {12000.0, 11800.0, 12100.0, 11950.0}},
    };
    const aerosim::Quat attitudes[] = {
            {0.0, std::sin(0.25 * 0.5), 0.0, std::cos(0.25 * 0.5)},
            {std::sin(-0.15 * 0.5), 0.0, 0.0, std::cos(-0.15 * 0.5)},
            {0.0, 0.0, std::sin(0.4 * 0.5), std::cos(0.4 * 0.5)},
    };
    const aerosim::Vec3 velocities[] = {
            {8.0, -2.0, 1.0},
            {-3.0, 4.0, 6.0},
            {18.0, 0.5, -2.0},
    };

    for (int index = 0; index < 3; ++index) {
        const aerosim::Vec3 force = aerosim::a3_drag_force_body(configs[index], attitudes[index], velocities[index]);
        out << index << ","
            << configs[index].coefficient.x << ","
            << configs[index].coefficient.y << ","
            << configs[index].coefficient.z;
        for (double rpm : configs[index].motor_rpm) {
            out << "," << rpm;
        }
        out << ","
            << attitudes[index].x << ","
            << attitudes[index].y << ","
            << attitudes[index].z << ","
            << attitudes[index].w << ","
            << velocities[index].x << ","
            << velocities[index].y << ","
            << velocities[index].z << ","
            << force.x << ","
            << force.y << ","
            << force.z << "\n";
    }
    return true;
}

} // namespace

int main() {
    aerosim::A3DragConfig drag;
    drag.enabled = true;
    drag.coefficient = {1.0e-6, 1.0e-6, 1.2e-6};
    drag.motor_rpm = {4000.0, 5000.0, 6000.0, 7000.0};

    aerosim::Quat attitude;
    const double yaw = 0.25;
    attitude.y = std::sin(yaw * 0.5);
    attitude.w = std::cos(yaw * 0.5);

    const aerosim::Vec3 force = aerosim::a3_drag_force_body(drag, attitude, {8.0, -2.0, 1.0});
    if (!near(force.x, -0.017173738424413127, 1e-12) ||
            !near(force.y, 0.004607669225265029, 1e-12) ||
            !near(force.z, -0.0072384792055590445, 1e-12)) {
        return fail("A3 drag must match the Forster/gym-pybullet-drones body-frame force at an oracle point");
    }

    aerosim::SimulationConfig coast;
    coast.seconds = 1.0;
    coast.physics_hz = 100;
    coast.substep_hz = 1000;
    coast.gravity_mps2 = 0.0;
    coast.initial_state.velocity = {10.0, 0.0, 0.0};

    auto off = aerosim::simulate_trajectory(coast);
    if (off.empty() || !near(off.back().state.velocity.x, 10.0, 1e-12)) {
        return fail("A3 off must leave an unpowered coasting body at constant velocity");
    }

    coast.a3_drag = drag;
    auto on = aerosim::simulate_trajectory(coast);
    if (on.empty() || !(on.back().state.velocity.x < 9.99)) {
        return fail("A3 on must make an unpowered coasting body decelerate from body drag");
    }

    const aerosim::A3ForwardFlightEquilibrium equilibrium =
            aerosim::a3_forward_flight_equilibrium(drag, 0.72, 9.80665, 18.0);
    const double drag_newtons = 1.0e-6 * (4000.0 + 5000.0 + 6000.0 + 7000.0) * 2.0 * kPi / 60.0 * 18.0;
    const double weight_newtons = 0.72 * 9.80665;
    const double analytic_pitch = std::atan2(drag_newtons, weight_newtons);
    const double analytic_thrust = std::sqrt(weight_newtons * weight_newtons + drag_newtons * drag_newtons);
    if (!near(equilibrium.pitch_radians, analytic_pitch, analytic_pitch * 0.05) ||
            !near(equilibrium.thrust_newtons, analytic_thrust, analytic_thrust * 0.05)) {
        return fail("G3.1 steady forward-flight pitch and thrust must stay within 5% of the Forster analytic solution");
    }

    aerosim::SimulationConfig forward;
    forward.seconds = 1.0;
    forward.physics_hz = 100;
    forward.substep_hz = 1000;
    forward.mass_kg = 0.72;
    forward.gravity_mps2 = 9.80665;
    forward.total_thrust_newtons = analytic_thrust;
    forward.a3_drag = drag;
    forward.initial_state.velocity = {18.0, 0.0, 0.0};
    forward.initial_state.orientation = {0.0, 0.0, std::sin(-analytic_pitch * 0.5), std::cos(analytic_pitch * 0.5)};
    const auto forward_samples = aerosim::simulate_trajectory(forward);
    if (forward_samples.empty()) {
        return fail("G3.1 forward-flight equilibrium must produce simulation samples");
    }
    const aerosim::Vec3 final_velocity = forward_samples.back().state.velocity;
    if (std::abs(final_velocity.x - 18.0) > 18.0 * 0.05 ||
            std::abs(final_velocity.y) > 18.0 * 0.05 ||
            std::abs(final_velocity.z) > 18.0 * 0.05) {
        return fail("G3.1 analytic pitch/thrust must hold steady forward flight in the integrator within 5%");
    }

    if (!write_oracle_cases(std::getenv("AEROSIM_A3_ORACLE_CASES"))) {
        return fail("A3 oracle case artifact must be writable for CI-A comparison");
    }

    return EXIT_SUCCESS;
}
