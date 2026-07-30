#include "aerosim_aerodynamics.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance = 1e-12) {
    return std::abs(actual - expected) <= tolerance;
}

} // namespace

int main() {
    const aerosim::Vec3 frd_basis_x = aerosim::y_up_to_frd({1.0, 0.0, 0.0});
    const aerosim::Vec3 frd_basis_y = aerosim::y_up_to_frd({0.0, 1.0, 0.0});
    const aerosim::Vec3 frd_basis_z = aerosim::y_up_to_frd({0.0, 0.0, 1.0});
    if (!near(frd_basis_x.x, 1.0) || !near(frd_basis_x.y, 0.0) || !near(frd_basis_x.z, 0.0) ||
            !near(frd_basis_y.x, 0.0) || !near(frd_basis_y.y, 0.0) || !near(frd_basis_y.z, -1.0) ||
            !near(frd_basis_z.x, 0.0) || !near(frd_basis_z.y, 1.0) || !near(frd_basis_z.z, 0.0) ||
            !near(aerosim::frd_to_y_up({1.0, 2.0, 3.0}).x, 1.0) ||
            !near(aerosim::frd_to_y_up({1.0, 2.0, 3.0}).y, -3.0) ||
            !near(aerosim::frd_to_y_up({1.0, 2.0, 3.0}).z, 2.0)) {
        return fail("Godot Y-up to FRD basis must match the frozen external contract");
    }

    aerosim::BodyDragConfig config;
    config.enabled = true;
    config.drag_coefficient = {1.0, 2.0, 3.0};
    config.frontal_area_m2 = {2.0, 3.0, 4.0};
    config.center_of_pressure_frd_m = {0.1, -0.2, 0.3};

    const aerosim::BodyDragWrench wrench = aerosim::body_drag_wrench_body_frd(
            config, {2.0, -3.0, 4.0}, {0.0, 0.0, 0.0}, 1.25);
    if (!near(wrench.force_body_frd_n.x, -5.0) ||
            !near(wrench.force_body_frd_n.y, 33.75) ||
            !near(wrench.force_body_frd_n.z, -120.0)) {
        return fail("body drag must use density, Cd, frontal area, and signed quadratic airspeed");
    }
    if (!near(wrench.torque_body_frd_nm.x, 13.875) ||
            !near(wrench.torque_body_frd_nm.y, 10.5) ||
            !near(wrench.torque_body_frd_nm.z, 2.375)) {
        return fail("body drag torque must equal center-of-pressure cross force");
    }

    const aerosim::BodyDragWrench angular_rate_wrench = aerosim::body_drag_wrench_body_frd(
            config, {}, {0.0, 1.0, 0.0}, 1.0);
    if (!near(angular_rate_wrench.force_body_frd_n.x, -0.09) ||
            !near(angular_rate_wrench.force_body_frd_n.y, 0.0) ||
            !near(angular_rate_wrench.force_body_frd_n.z, 0.06) ||
            !near(angular_rate_wrench.torque_body_frd_nm.x, -0.012) ||
            !near(angular_rate_wrench.torque_body_frd_nm.y, -0.033) ||
            !near(angular_rate_wrench.torque_body_frd_nm.z, -0.018)) {
        return fail("CP and angular-rate signs must stay in the FRD basis");
    }

    const aerosim::BodyDragWrench doubled_speed = aerosim::body_drag_wrench_body_frd(
            config, {4.0, -6.0, 8.0}, {0.0, 0.0, 0.0}, 1.25);
    if (!near(doubled_speed.force_body_frd_n.x, 4.0 * wrench.force_body_frd_n.x) ||
            !near(doubled_speed.force_body_frd_n.y, 4.0 * wrench.force_body_frd_n.y) ||
            !near(doubled_speed.force_body_frd_n.z, 4.0 * wrench.force_body_frd_n.z) ||
            !near(doubled_speed.torque_body_frd_nm.x, 4.0 * wrench.torque_body_frd_nm.x) ||
            !near(doubled_speed.torque_body_frd_nm.y, 4.0 * wrench.torque_body_frd_nm.y) ||
            !near(doubled_speed.torque_body_frd_nm.z, 4.0 * wrench.torque_body_frd_nm.z)) {
        return fail("body drag force and torque must scale with airspeed squared");
    }

    const aerosim::BodyDragWrench no_flow = aerosim::body_drag_wrench_body_frd(
            config, {}, {}, 1.25);
    if (!near(no_flow.force_body_frd_n.x, 0.0) || !near(no_flow.force_body_frd_n.y, 0.0) ||
            !near(no_flow.force_body_frd_n.z, 0.0) || !near(no_flow.torque_body_frd_nm.x, 0.0) ||
            !near(no_flow.torque_body_frd_nm.y, 0.0) || !near(no_flow.torque_body_frd_nm.z, 0.0)) {
        return fail("zero relative airspeed must produce zero body drag wrench");
    }

    aerosim::BodyDragConfig incomplete = config;
    incomplete.drag_coefficient.y = 0.0;
    if (aerosim::validate_body_drag_config(incomplete, 1.25) ||
            aerosim::body_drag_wrench_body_frd(incomplete, {2.0, 0.0, 0.0}, {}, 1.25).force_body_frd_n.x != 0.0) {
        return fail("enabled body drag with an omitted coefficient must be unavailable, not a precise zero");
    }

    config.enabled = false;
    const aerosim::BodyDragWrench disabled = aerosim::body_drag_wrench_body_frd(
            config, {10.0, 10.0, 10.0}, {}, 1.25);
    if (!near(disabled.force_body_frd_n.x, 0.0) || !near(disabled.torque_body_frd_nm.z, 0.0)) {
        return fail("disabled body drag must remain exactly zero");
    }

    aerosim::SimulationConfig axis_config;
    axis_config.seconds = 0.01;
    axis_config.physics_hz = 100;
    axis_config.substep_hz = 1000;
    axis_config.mass_kg = 1.0;
    axis_config.gravity_mps2 = 0.0;
    axis_config.body_drag.enabled = true;
    axis_config.body_drag.drag_coefficient = {1.0, 2.0, 3.0};
    axis_config.body_drag.frontal_area_m2 = {1.0, 1.0, 1.0};
    axis_config.initial_state.velocity = {10.0, 0.0, 0.0};
    const auto aligned = aerosim::simulate_trajectory(axis_config);
    axis_config.initial_state.orientation = {0.0, std::sin(0.25 * 3.14159265358979323846), 0.0,
            std::cos(0.25 * 3.14159265358979323846)};
    const auto rotated = aerosim::simulate_trajectory(axis_config);
    if (aligned.empty() || rotated.empty() ||
            !(aligned.front().body_drag_force_body_frd_n_mean.x < 0.0) ||
            !near(aligned.front().body_drag_force_body_frd_n_mean.y, 0.0) ||
            !(std::abs(rotated.front().body_drag_force_body_frd_n_mean.y) > 0.1)) {
        return fail("body drag axes must rotate with the body attitude in the native integrator");
    }

    aerosim::SimulationConfig inertia_config;
    inertia_config.physics_hz = 1000;
    inertia_config.substep_hz = 1000;
    inertia_config.mass_kg = 1.0;
    inertia_config.gravity_mps2 = 0.0;
    inertia_config.per_motor.inertia_kg_m2 = {0.01, 0.02, 0.05};
    inertia_config.per_motor.max_thrust_per_motor_newtons = 1.0;
    inertia_config.per_motor.max_current_per_motor_a = 1.0;
    inertia_config.per_motor.yaw_torque_per_newton = 0.01;
    inertia_config.per_motor.position_frd = {{{-0.1, 0.1, 0.0}, {0.1, 0.1, 0.0},
            {-0.1, -0.1, 0.0}, {0.1, -0.1, 0.0}}};
    inertia_config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    inertia_config.body_drag = config;
    inertia_config.body_drag.enabled = true;
    inertia_config.air_density_kg_m3 = 1.25;
    aerosim::RigidBodyState inertia_state;
    inertia_state.velocity = {2.0, -4.0, -3.0};
    aerosim::SimulationClock inertia_clock;
    const aerosim::TrajectorySample inertia_sample = aerosim::step_per_motor_physics_frame(
            inertia_state, inertia_clock, inertia_config, aerosim::MotorCommands{});
    if (!near(inertia_sample.state.angular_velocity.y,
                    -wrench.torque_body_frd_nm.z / inertia_config.per_motor.inertia_kg_m2.z / 1000.0) ||
            !near(inertia_sample.state.angular_velocity.z,
                    wrench.torque_body_frd_nm.y / inertia_config.per_motor.inertia_kg_m2.y / 1000.0)) {
        return fail("FRD pitch/yaw inertia must map to internal Z/Y angular acceleration axes");
    }
    return EXIT_SUCCESS;
}
