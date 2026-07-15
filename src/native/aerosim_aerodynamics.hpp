#pragma once

#include "aerosim_simulation.hpp"

namespace aerosim {

struct A3ForwardFlightEquilibrium {
    double pitch_radians = 0.0;
    double thrust_newtons = 0.0;
};

Vec3 a3_drag_force_body(
        const A3DragConfig &config,
        const Quat &body_attitude,
        const Vec3 &relative_air_velocity_world,
        const std::array<double, 4> &motor_speed_rad_s);
A3ForwardFlightEquilibrium a3_forward_flight_equilibrium(
        const A3DragConfig &config,
        double mass_kg,
        double gravity_mps2,
        double forward_speed_mps,
        const std::array<double, 4> &motor_speed_rad_s);
double a4_ground_effect_lift_newtons(
        const A4GroundEffectConfig &config,
        double height_m);
double a5_downwash_force_y_newtons(
        const A5DownwashConfig &config,
        const Vec3 &upper_position,
        const Vec3 &lower_position);

} // namespace aerosim
