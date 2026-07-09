#include "aerosim_aerodynamics.hpp"

#include <cmath>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

Quat conjugate(const Quat &q) {
    return {-q.x, -q.y, -q.z, q.w};
}

Quat multiply(const Quat &a, const Quat &b) {
    return {
            a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

Vec3 rotate_inverse(const Quat &q, const Vec3 &v) {
    const Quat vector{v.x, v.y, v.z, 0.0};
    const Quat rotated = multiply(multiply(conjugate(q), vector), q);
    return {rotated.x, rotated.y, rotated.z};
}

} // namespace

Vec3 a3_drag_force_body(
        const A3DragConfig &config,
        const Quat &body_attitude,
        const Vec3 &world_velocity) {
    if (!config.enabled) {
        return {};
    }
    if (!std::isfinite(config.coefficient.x) || config.coefficient.x < 0.0 ||
            !std::isfinite(config.coefficient.y) || config.coefficient.y < 0.0 ||
            !std::isfinite(config.coefficient.z) || config.coefficient.z < 0.0) {
        return {};
    }

    double rotor_speed_sum = 0.0;
    for (double rpm : config.motor_rpm) {
        if (!std::isfinite(rpm) || rpm < 0.0) {
            return {};
        }
        rotor_speed_sum += 2.0 * kPi * rpm / 60.0;
    }

    const Vec3 drag_scaled_world{
            -config.coefficient.x * rotor_speed_sum * world_velocity.x,
            -config.coefficient.y * rotor_speed_sum * world_velocity.y,
            -config.coefficient.z * rotor_speed_sum * world_velocity.z,
    };
    return rotate_inverse(body_attitude, drag_scaled_world);
}

A3ForwardFlightEquilibrium a3_forward_flight_equilibrium(
        const A3DragConfig &config,
        double mass_kg,
        double gravity_mps2,
        double forward_speed_mps) {
    if (!config.enabled ||
            !std::isfinite(mass_kg) || mass_kg <= 0.0 ||
            !std::isfinite(gravity_mps2) || gravity_mps2 <= 0.0 ||
            !std::isfinite(forward_speed_mps) || forward_speed_mps < 0.0 ||
            !std::isfinite(config.coefficient.x) || config.coefficient.x < 0.0) {
        return {};
    }

    double rotor_speed_sum = 0.0;
    for (double rpm : config.motor_rpm) {
        if (!std::isfinite(rpm) || rpm < 0.0) {
            return {};
        }
        rotor_speed_sum += 2.0 * kPi * rpm / 60.0;
    }

    const double drag_newtons = config.coefficient.x * rotor_speed_sum * forward_speed_mps;
    const double weight_newtons = mass_kg * gravity_mps2;
    return {
            std::atan2(drag_newtons, weight_newtons),
            std::sqrt(weight_newtons * weight_newtons + drag_newtons * drag_newtons),
    };
}

} // namespace aerosim
