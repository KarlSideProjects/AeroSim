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
        const Vec3 &world_velocity);
A3ForwardFlightEquilibrium a3_forward_flight_equilibrium(
        const A3DragConfig &config,
        double mass_kg,
        double gravity_mps2,
        double forward_speed_mps);

} // namespace aerosim
