#include "aerosim_collision.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace aerosim {
namespace {

double dot(const Vec3 &a, const Vec3 &b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

double length(const Vec3 &v) {
    return std::sqrt(dot(v, v));
}

Vec3 operator*(const Vec3 &v, double scale) {
    return {v.x * scale, v.y * scale, v.z * scale};
}

Vec3 operator-(const Vec3 &a, const Vec3 &b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 operator+(const Vec3 &a, const Vec3 &b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

bool finite(const Vec3 &v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

Vec3 normalized_or_zero(const Vec3 &v) {
    const double norm = length(v);
    if (!std::isfinite(norm) || norm == 0.0) {
        return {};
    }
    return v * (1.0 / norm);
}

void sanitize(Vec3 &v) {
    if (!finite(v)) {
        v = {};
    }
}

void clamp_energy(RigidBodyState &state, double mass_kg, double energy_limit) {
    const double after = kinetic_energy_joules(state, mass_kg);
    if (energy_limit > 0.0 && after > energy_limit * 1.01) {
        const double scale = std::sqrt((energy_limit * 1.01) / after);
        state.velocity = state.velocity * scale;
        state.angular_velocity = state.angular_velocity * scale;
    }
}

TrajectorySample sample_jolt_frame(
        const RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0) {
        return {};
    }
    const double substeps_per_frame = static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz);
    clock.substep_accumulator += substeps_per_frame;
    const auto frame_substeps = static_cast<std::uint64_t>(std::floor(clock.substep_accumulator + 1e-12));
    clock.substep_accumulator -= static_cast<double>(frame_substeps);
    clock.total_substeps += frame_substeps;
    const double dt = config.substep_hz > 0 ? 1.0 / static_cast<double>(config.substep_hz) : 0.0;
    return {
            static_cast<double>(clock.total_substeps) * dt,
            state,
            clock.total_substeps,
            {},
            {},
            {},
            {},
            {},
            config.air_density_kg_m3,
            false,
            false,
    };
}

void resolve_contact(RigidBodyState &state, const CollisionContact &contact, double mass_kg) {
    const double before = kinetic_energy_joules(state, mass_kg);
    const Vec3 normal = normalized_or_zero(contact.normal);
    const double normal_speed = dot(state.velocity, normal);
    if (contact.has_resolved_state && finite(contact.resolved_velocity) && finite(contact.resolved_angular_velocity)) {
        state.velocity = contact.resolved_velocity;
        state.angular_velocity = contact.resolved_angular_velocity;
    } else if (finite(contact.impulse) && length(contact.impulse) > 0.0 && mass_kg > 0.0) {
        state.velocity = state.velocity + contact.impulse * (1.0 / mass_kg);
    } else if (normal_speed < 0.0) {
        const double restitution = std::clamp(contact.restitution, 0.0, 1.0);
        state.velocity = state.velocity - normal * ((1.0 + restitution) * normal_speed);
    }

    sanitize(state.velocity);
    sanitize(state.angular_velocity);

    const double energy_limit = contact.max_kinetic_energy_joules > 0.0 ? contact.max_kinetic_energy_joules : before;
    clamp_energy(state, mass_kg, energy_limit);
}

} // namespace

double kinetic_energy_joules(const RigidBodyState &state, double mass_kg) {
    if (!std::isfinite(mass_kg) || mass_kg <= 0.0 || !finite(state.velocity) || !finite(state.angular_velocity)) {
        return std::numeric_limits<double>::infinity();
    }
    const double linear = 0.5 * mass_kg * dot(state.velocity, state.velocity);
    const double angular = 0.5 * dot(state.angular_velocity, state.angular_velocity);
    return linear + angular;
}

CollisionAuthoritySwitch::CollisionAuthoritySwitch(int release_frames) {
    set_release_frames(release_frames);
}

void CollisionAuthoritySwitch::set_release_frames(int release_frames) {
    release_frames_ = std::max(1, release_frames);
}

int CollisionAuthoritySwitch::release_frames() const {
    return release_frames_;
}

PhysicsAuthority CollisionAuthoritySwitch::current_authority() const {
    return authority_;
}

CollisionStepResult CollisionAuthoritySwitch::step(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const FlightCommand &command,
        const CollisionContact &contact) {
    return step(state, clock, controller, config, command, contact, state.orientation);
}

CollisionStepResult CollisionAuthoritySwitch::step(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const FlightCommand &command,
        const CollisionContact &contact,
        const Quat &estimated_attitude) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0) {
        return {authority_, {}, {}, {}};
    }
    if (contact.touching) {
        if (authority_ != PhysicsAuthority::Jolt) {
            controller.reset_integrators();
        }
        authority_ = PhysicsAuthority::Jolt;
        clear_frames_ = 0;
        resolve_contact(state, contact, config.mass_kg);

        CollisionStepResult result{authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
        const double energy_limit = contact.max_kinetic_energy_joules > 0.0 ? contact.max_kinetic_energy_joules : -1.0;
        clamp_energy(state, config.mass_kg, energy_limit);
        result.sample.state = state;
        return result;
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }

    return {authority_, controller.step_angle_mode(state, clock, config, command, estimated_attitude), {}, {}};
}

CollisionStepResult CollisionAuthoritySwitch::step_altitude_hold(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const FlightCommand &command,
        double measured_altitude_m,
        const CollisionContact &contact,
        const Quat &estimated_attitude) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0) {
        return {authority_, {}, {}, {}};
    }
    if (contact.touching) {
        if (authority_ != PhysicsAuthority::Jolt) {
            controller.reset_integrators();
        }
        authority_ = PhysicsAuthority::Jolt;
        clear_frames_ = 0;
        resolve_contact(state, contact, config.mass_kg);

        CollisionStepResult result{authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
        const double energy_limit = contact.max_kinetic_energy_joules > 0.0 ? contact.max_kinetic_energy_joules : -1.0;
        clamp_energy(state, config.mass_kg, energy_limit);
        result.sample.state = state;
        return result;
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }

    return {
            authority_,
            controller.step_altitude_hold_mode(
                    state,
                    clock,
                    config,
                    command,
                    measured_altitude_m,
                    estimated_attitude),
            {},
            {}};
}

CollisionStepResult CollisionAuthoritySwitch::step_acro(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const AcroCommand &command,
        const CollisionContact &contact) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0) {
        return {authority_, {}, {}, {}};
    }
    if (contact.touching) {
        if (authority_ != PhysicsAuthority::Jolt) {
            controller.reset_integrators();
        }
        authority_ = PhysicsAuthority::Jolt;
        clear_frames_ = 0;
        resolve_contact(state, contact, config.mass_kg);

        CollisionStepResult result{authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
        const double energy_limit = contact.max_kinetic_energy_joules > 0.0 ? contact.max_kinetic_energy_joules : -1.0;
        clamp_energy(state, config.mass_kg, energy_limit);
        result.sample.state = state;
        return result;
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }

    return {authority_, controller.step_acro_mode(state, clock, config, command), {}, {}};
}

CollisionStepResult CollisionAuthoritySwitch::step_per_motor(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const MotorCommands &commands,
        const CollisionContact &contact) {
    if (config.physics_hz <= 0 || config.substep_hz <= 0) {
        return {authority_, {}, {}, {}};
    }
    if (contact.touching) {
        authority_ = PhysicsAuthority::Jolt;
        clear_frames_ = 0;
        resolve_contact(state, contact, config.mass_kg);
        CollisionStepResult result{authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
        const double energy_limit = contact.max_kinetic_energy_joules > 0.0 ? contact.max_kinetic_energy_joules : -1.0;
        clamp_energy(state, config.mass_kg, energy_limit);
        result.sample.state = state;
        return result;
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }
    return {authority_, step_per_motor_physics_frame(state, clock, config, commands), {}, {}};
}

} // namespace aerosim
