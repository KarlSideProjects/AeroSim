#pragma once

#include "aerosim_flight_control.hpp"

namespace aerosim {

enum class PhysicsAuthority {
    FlightCore,
    Jolt,
};

struct CollisionContact {
    bool touching = false;
    Vec3 normal;
    Vec3 impulse;
    double restitution = 0.0;
    bool has_resolved_state = false;
    Vec3 resolved_velocity;
    Vec3 resolved_angular_velocity;
    double max_kinetic_energy_joules = -1.0;
};

struct CollisionStepResult {
    PhysicsAuthority authority = PhysicsAuthority::FlightCore;
    TrajectorySample sample;
    Vec3 normal;
    Vec3 impulse;
    StepStatus status = StepStatus::Ok;
};

double kinetic_energy_joules(const RigidBodyState &state, double mass_kg);

class CollisionAuthoritySwitch {
private:
    PhysicsAuthority authority_ = PhysicsAuthority::FlightCore;
    int clear_frames_ = 0;
    int release_frames_ = 3;
    CollisionStepResult step_impl(
            RigidBodyState &state,
            SimulationClock &clock,
            FlightController &controller,
            const SimulationConfig &config,
            const FlightCommand &command,
            const CollisionContact &contact,
            const Quat &estimated_attitude);

public:
    CollisionAuthoritySwitch() = default;
    explicit CollisionAuthoritySwitch(int release_frames);
    void set_release_frames(int release_frames);
    int release_frames() const;
    PhysicsAuthority current_authority() const;
    CollisionStepResult step(
            RigidBodyState &state,
            SimulationClock &clock,
            FlightController &controller,
            const SimulationConfig &config,
            const FlightCommand &command,
            const CollisionContact &contact);
    CollisionStepResult step(
            RigidBodyState &state,
            SimulationClock &clock,
            FlightController &controller,
            const SimulationConfig &config,
            const FlightCommand &command,
            const CollisionContact &contact,
            const Quat &estimated_attitude);
    CollisionStepResult try_step(
            RigidBodyState &state,
            SimulationClock &clock,
            FlightController &controller,
            const SimulationConfig &config,
            const FlightCommand &command,
            const CollisionContact &contact,
            const Quat &estimated_attitude = {});
    CollisionStepResult step_altitude_hold(
            RigidBodyState &state,
            SimulationClock &clock,
            FlightController &controller,
            const SimulationConfig &config,
            const FlightCommand &command,
            double measured_altitude_m,
            const CollisionContact &contact,
            const Quat &estimated_attitude);
    CollisionStepResult step_acro(
            RigidBodyState &state,
            SimulationClock &clock,
            FlightController &controller,
            const SimulationConfig &config,
            const AcroCommand &command,
            const CollisionContact &contact);
    CollisionStepResult step_per_motor(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const MotorCommands &commands,
            const CollisionContact &contact);
};

} // namespace aerosim
