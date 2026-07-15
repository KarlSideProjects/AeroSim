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

std::array<double, 4> rpm_to_speed(const std::array<double, 4> &rpm) {
    std::array<double, 4> speed{};
    for (std::size_t index = 0; index < speed.size(); ++index) {
        speed[index] = rpm[index] * 2.0 * kPi / 60.0;
    }
    return speed;
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
            {true, {1.0e-6, 1.0e-6, 1.2e-6}},
            {true, {1.4e-6, 0.9e-6, 1.8e-6}},
            {true, {0.8e-6, 1.1e-6, 1.5e-6}},
    };
    const std::array<double, 4> motor_rpm[] = {
            {4000.0, 5000.0, 6000.0, 7000.0},
            {8200.0, 8100.0, 8300.0, 8050.0},
            {12000.0, 11800.0, 12100.0, 11950.0},
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
        const auto motor_speed_rad_s = rpm_to_speed(motor_rpm[index]);
        const aerosim::Vec3 force = aerosim::a3_drag_force_body(
                configs[index], attitudes[index], velocities[index], motor_speed_rad_s);
        out << index << ","
            << configs[index].coefficient.x << ","
            << configs[index].coefficient.y << ","
            << configs[index].coefficient.z;
        for (double rpm : motor_rpm[index]) {
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

bool write_a4_a5_oracle_cases(const char *path) {
    if (path == nullptr || path[0] == '\0') {
        return true;
    }

    std::ofstream out(path);
    if (!out) {
        return false;
    }

    out << std::setprecision(17)
        << "effect,case,kf,gnd_eff_coeff,prop_radius,height_clip,rpm_0,rpm_1,rpm_2,rpm_3,height,force_y,dw_coeff_1,dw_coeff_2,dw_coeff_3,upper_x,upper_y,upper_z,lower_x,lower_y,lower_z\n";

    const aerosim::A4GroundEffectConfig ground{
            true,
            3.16e-10,
            11.36859,
            2.31348e-2,
            2.31348e-2,
            {9000.0, 10000.0, 11000.0, 12000.0},
    };
    const double heights[] = {
            ground.prop_radius_m,
            2.5 * ground.prop_radius_m,
            5.0 * ground.prop_radius_m,
    };
    for (int index = 0; index < 3; ++index) {
        const double force_y = aerosim::a4_ground_effect_lift_newtons(ground, heights[index]);
        out << "a4," << index << ","
            << ground.kf << ","
            << ground.ground_effect_coeff << ","
            << ground.prop_radius_m << ","
            << ground.height_clip_m;
        for (double rpm : ground.motor_rpm) {
            out << "," << rpm;
        }
        out << "," << heights[index] << ","
            << force_y << ",,,,,,,,,\n";
    }

    const aerosim::A5DownwashConfig downwash{
            true,
            2.31348e-2,
            2267.18,
            0.16,
            -0.11,
    };
    const aerosim::Vec3 uppers[] = {
            {0.1, 2.0, 0.0},
            {0.0, 3.0, 0.2},
            {-0.3, 4.0, 0.1},
    };
    const aerosim::Vec3 lower{0.0, 0.0, 0.0};
    for (int index = 0; index < 3; ++index) {
        const double force_y = aerosim::a5_downwash_force_y_newtons(downwash, uppers[index], lower);
        out << "a5," << index << ",,,"
            << downwash.prop_radius_m << ",,,,,,,"
            << force_y << ","
            << downwash.coeff_1 << ","
            << downwash.coeff_2 << ","
            << downwash.coeff_3 << ","
            << uppers[index].x << ","
            << uppers[index].y << ","
            << uppers[index].z << ","
            << lower.x << ","
            << lower.y << ","
            << lower.z << "\n";
    }
    return true;
}

} // namespace

int main() {
    aerosim::A4GroundEffectConfig ground;
    ground.enabled = true;
    ground.kf = 3.16e-10;
    ground.ground_effect_coeff = 11.36859;
    ground.prop_radius_m = 2.31348e-2;
    ground.height_clip_m = ground.prop_radius_m;
    ground.motor_rpm = {12000.0, 12000.0, 12000.0, 12000.0};

    aerosim::A4GroundEffectConfig ground_off = ground;
    ground_off.enabled = false;
    if (!near(aerosim::a4_ground_effect_lift_newtons(ground_off, ground.prop_radius_m), 0.0, 1e-12)) {
        return fail("A4 disabled ground effect must not add lift");
    }

    const double base_lift = 4.0 * ground.kf * 12000.0 * 12000.0;
    const double low_lift = aerosim::a4_ground_effect_lift_newtons(ground, ground.prop_radius_m);
    const double high_lift = aerosim::a4_ground_effect_lift_newtons(ground, 5.0 * ground.prop_radius_m);
    if (!near(low_lift / base_lift, ground.ground_effect_coeff / 16.0, 1e-12) ||
            !(low_lift > high_lift * 20.0)) {
        return fail("G3.2 A4 lift gain must follow the Shi/gym-pybullet-drones z/R curve and switch");
    }

    aerosim::SimulationConfig hover;
    hover.seconds = 0.5;
    hover.physics_hz = 100;
    hover.substep_hz = 1000;
    hover.mass_kg = 0.72;
    hover.gravity_mps2 = 9.80665;
    hover.total_thrust_newtons = hover.mass_kg * hover.gravity_mps2;
    hover.initial_state.position.y = ground.prop_radius_m;
    const auto hover_off = aerosim::simulate_trajectory(hover);
    hover.a4_ground_effect = ground;
    const auto hover_on = aerosim::simulate_trajectory(hover);
    if (hover_off.empty() || hover_on.empty() ||
            std::abs(hover_off.back().state.position.y - hover.initial_state.position.y) > 1e-9 ||
            !(hover_on.back().state.position.y > hover.initial_state.position.y + 0.01)) {
        return fail("G3.2 low-altitude hover must show an observable A4 cushion when enabled");
    }

    aerosim::A5DownwashConfig downwash;
    downwash.enabled = true;
    downwash.prop_radius_m = 2.31348e-2;
    downwash.coeff_1 = 2267.18;
    downwash.coeff_2 = 0.16;
    downwash.coeff_3 = -0.11;

    aerosim::A5DownwashConfig downwash_off = downwash;
    downwash_off.enabled = false;
    if (!near(aerosim::a5_downwash_force_y_newtons(downwash_off, {0.1, 2.0, 0.0}, {0.0, 0.0, 0.0}), 0.0, 1e-12)) {
        return fail("A5 disabled downwash must not reduce lift");
    }

    const double dz = 2.0;
    const double dxy = 0.1;
    const double alpha = downwash.coeff_1 * std::pow(downwash.prop_radius_m / (4.0 * dz), 2.0);
    const double beta = downwash.coeff_2 * dz + downwash.coeff_3;
    const double expected_downwash = -alpha * std::exp(-0.5 * std::pow(dxy / beta, 2.0));
    const double actual_downwash = aerosim::a5_downwash_force_y_newtons(downwash, {dxy, dz, 0.0}, {0.0, 0.0, 0.0});
    if (!near(actual_downwash, expected_downwash, 1e-12) || !(actual_downwash < 0.0)) {
        return fail("G3.3 A5 dual-aircraft lift reduction must follow the DSL/gym-pybullet-drones downwash model and switch");
    }

    aerosim::A3DragConfig drag;
    drag.enabled = true;
    drag.coefficient = {1.0e-6, 1.0e-6, 1.2e-6};
    const std::array<double, 4> drag_rpm = {4000.0, 5000.0, 6000.0, 7000.0};
    const auto drag_speed_rad_s = rpm_to_speed(drag_rpm);

    aerosim::Quat attitude;
    const double yaw = 0.25;
    attitude.y = std::sin(yaw * 0.5);
    attitude.w = std::cos(yaw * 0.5);

    const aerosim::Vec3 force = aerosim::a3_drag_force_body(drag, attitude, {8.0, -2.0, 1.0}, drag_speed_rad_s);
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
    coast.initial_state.motor_thrust_newtons = {1.0, 1.0, 1.0, 1.0};
    coast.max_total_thrust_newtons = 4.0;
    coast.max_motor_rpm = 10000.0;
    coast.per_motor.max_thrust_per_motor_newtons = 1.0;

    auto off = aerosim::simulate_trajectory(coast);
    if (off.empty() || !near(off.back().state.velocity.x, 10.0, 1e-12)) {
        return fail("A3 off must leave an unpowered coasting body at constant velocity");
    }

    coast.a3_drag = drag;
    auto on = aerosim::simulate_trajectory(coast);
    if (on.empty() || !(on.back().state.velocity.x < 9.99)) {
        return fail("A3 on must make an unpowered coasting body decelerate from body drag");
    }
    coast.wind_world_mps = {10.0, 0.0, 0.0};
    auto matching_wind = aerosim::simulate_trajectory(coast);
    if (matching_wind.empty() || !near(matching_wind.back().state.velocity.x, 10.0, 1e-12)) {
        return fail("A3 must use zero relative airspeed when vehicle velocity matches wind");
    }

    const aerosim::A3ForwardFlightEquilibrium equilibrium =
            aerosim::a3_forward_flight_equilibrium(drag, 0.72, 9.80665, 18.0, drag_speed_rad_s);
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
    forward.max_total_thrust_newtons = analytic_thrust;
    forward.max_motor_rpm = 10000.0;
    forward.per_motor.max_thrust_per_motor_newtons = analytic_thrust / 4.0;
    forward.initial_state.motor_thrust_newtons = {analytic_thrust / 4.0, analytic_thrust / 4.0, analytic_thrust / 4.0, analytic_thrust / 4.0};
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

    const double zero_speed = aerosim::motor_speed_rad_s_from_thrust(0.0, 1.0, 10000.0);
    if (!near(zero_speed, 0.0, 1e-12)) {
        return fail("A3 must use zero force when live motor state is zero");
    }
    const double half_motor_speed = aerosim::motor_speed_rad_s_from_thrust(0.25, 1.0, 10000.0);
    const double full_motor_speed = aerosim::motor_speed_rad_s_from_thrust(1.0, 1.0, 10000.0);
    const std::array<double, 4> half_speed = {half_motor_speed, half_motor_speed, half_motor_speed, half_motor_speed};
    const std::array<double, 4> full_speed = {full_motor_speed, full_motor_speed, full_motor_speed, full_motor_speed};
    const double half_force = aerosim::a3_drag_force_body(drag, {}, {1.0, 0.0, 0.0}, half_speed).x;
    const double full_force = aerosim::a3_drag_force_body(drag, {}, {1.0, 0.0, 0.0}, full_speed).x;
    if (!near(full_force, 2.0 * half_force, 1e-12)) {
        return fail("A3 force must scale linearly with the live rotor speed sum");
    }
    const aerosim::Vec3 velocity{8.0, -2.0, 1.0};
    const aerosim::Vec3 wind{3.0, -2.0, 1.0};
    const aerosim::Vec3 relative_force = aerosim::a3_drag_force_body(
            drag, {}, {velocity.x - wind.x, velocity.y - wind.y, velocity.z - wind.z}, full_speed);
    const aerosim::Vec3 stationary_air_force = aerosim::a3_drag_force_body(
            drag, {}, {0.0, 0.0, 0.0}, full_speed);
    if (!near(stationary_air_force.x, 0.0, 1e-12) ||
            !near(stationary_air_force.y, 0.0, 1e-12) ||
            !near(stationary_air_force.z, 0.0, 1e-12)) {
        return fail("A3 must be zero when vehicle velocity matches wind");
    }
    const aerosim::Vec3 crosswind_force = aerosim::a3_drag_force_body(
            drag, {}, {-5.0, 0.0, 0.0}, full_speed);
    if (!(crosswind_force.x > 0.0)) {
        return fail("A3 stationary crosswind must push opposite the relative airflow");
    }
    const aerosim::Vec3 shifted_force = aerosim::a3_drag_force_body(
            drag, {}, {velocity.x + 4.0 - (wind.x + 4.0), velocity.y - wind.y, velocity.z - wind.z}, full_speed);
    if (!near(relative_force.x, shifted_force.x, 1e-12) ||
            !near(relative_force.y, shifted_force.y, 1e-12) ||
            !near(relative_force.z, shifted_force.z, 1e-12)) {
        return fail("A3 relative-air force must be Galilean invariant");
    }

    if (!write_oracle_cases(std::getenv("AEROSIM_A3_ORACLE_CASES"))) {
        return fail("A3 oracle case artifact must be writable for CI-A comparison");
    }
    if (!write_a4_a5_oracle_cases(std::getenv("AEROSIM_A4_A5_ORACLE_CASES"))) {
        return fail("A4/A5 oracle case artifact must be writable for CI-A comparison");
    }

    return EXIT_SUCCESS;
}
