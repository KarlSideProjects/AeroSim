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

bool finite(const Quat &q) {
    return finite(Vec3{q.x, q.y, q.z}) && std::isfinite(q.w) && quat_norm(q) > 0.0;
}

bool valid_state(const RigidBodyState &state) {
    if (!finite(state.position) || !finite(state.velocity) || !finite(state.orientation) ||
            !finite(state.angular_velocity) || !finite(state.propwash_disturbance_rad_s2)) {
        return false;
    }
    return std::all_of(state.motor_thrust_newtons.begin(), state.motor_thrust_newtons.end(),
            [](double value) { return std::isfinite(value) && value >= 0.0; });
}

bool valid_config(const SimulationConfig &config) {
    const double values[] = {
            config.seconds, config.mass_kg, config.gravity_mps2, config.total_thrust_newtons,
            config.max_total_thrust_newtons, config.hover_throttle, config.motor_tau_s,
            config.battery_nominal_voltage_v, config.battery_cells, config.battery_cell_resistance_ohm,
            config.battery_remaining_mah, config.max_total_current_a, config.max_motor_rpm, config.air_density_kg_m3,
            config.a4_ground_effect.kf, config.a4_ground_effect.ground_effect_coeff,
            config.a4_ground_effect.prop_radius_m, config.a4_ground_effect.height_clip_m,
            config.a5_downwash.prop_radius_m, config.a5_downwash.coeff_1, config.a5_downwash.coeff_2,
            config.a5_downwash.coeff_3, config.a6_propwash.full_collective_angular_accel_rad_s2,
            config.a6_propwash.minimum_wake_entry_speed_mps, config.a6_propwash.minimum_transverse_rate_rad_s,
    };
    return config.physics_hz > 0 && config.substep_hz >= config.physics_hz &&
            static_cast<double>(config.substep_hz) / static_cast<double>(config.physics_hz) <= 1000000.0 &&
            std::all_of(std::begin(values), std::end(values), [](double value) { return std::isfinite(value); }) &&
            finite(config.external_force_world) && finite(config.wind_world_mps) && finite(config.wind_turbulence_mps) &&
            finite(config.a3_drag.coefficient) && finite(config.body_drag.drag_coefficient) &&
            finite(config.body_drag.frontal_area_m2) && finite(config.body_drag.center_of_pressure_frd_m) &&
            std::all_of(config.a4_ground_effect.motor_rpm.begin(), config.a4_ground_effect.motor_rpm.end(),
                    [](double value) { return std::isfinite(value); }) &&
            config.mass_kg > 0.0 && config.gravity_mps2 > 0.0 && config.air_density_kg_m3 > 0.0 &&
            config.hover_throttle >= 0.0 && config.hover_throttle <= 1.0 && config.motor_tau_s >= 0.0 &&
            valid_state(config.initial_state) && validate_per_motor_config(config.per_motor);
}

bool valid_clock(const SimulationClock &clock, const SimulationConfig &config) {
    if (!std::isfinite(clock.substep_accumulator) || clock.substep_accumulator < 0.0 ||
            clock.substep_accumulator >= 1.0) {
        return false;
    }
    const std::uint64_t maximum_frame_substeps =
            static_cast<std::uint64_t>(config.substep_hz / config.physics_hz) +
            (config.substep_hz % config.physics_hz == 0 ? 0U : 1U);
    return clock.total_substeps <= std::numeric_limits<std::uint64_t>::max() - maximum_frame_substeps;
}

bool valid_command(const FlightCommand &command) {
    return std::isfinite(command.throttle) && command.throttle >= 0.0 && command.throttle <= 1.0 &&
            std::isfinite(command.roll_degrees) && std::isfinite(command.pitch_degrees) &&
            std::isfinite(command.yaw_rate_degrees_per_second);
}

bool valid_command(const AcroCommand &command) {
    return std::isfinite(command.throttle) && command.throttle >= 0.0 && command.throttle <= 1.0 &&
            std::isfinite(command.roll_stick) && std::isfinite(command.pitch_stick) &&
            std::isfinite(command.yaw_stick) && std::isfinite(command.rates.rc_rate) &&
            command.rates.rc_rate >= 0.0 && command.rates.rc_rate <= 3.0 &&
            std::isfinite(command.rates.super_rate) && command.rates.super_rate >= 0.0 && command.rates.super_rate <= 1.0 &&
            std::isfinite(command.rates.expo) && command.rates.expo >= 0.0 && command.rates.expo <= 1.0;
}

bool valid_commands(const MotorCommands &commands) {
    return std::all_of(commands.normalized.begin(), commands.normalized.end(),
            [](double value) { return std::isfinite(value) && value >= 0.0 && value <= 1.0; });
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

void clamp_energy(RigidBodyState &state, const SimulationConfig &config, double energy_limit) {
    if (energy_limit < 0.0) {
        return;
    }
    const double after = kinetic_energy_joules(state, config);
    if (!std::isfinite(after) || energy_limit == 0.0) {
        state.velocity = {};
        state.angular_velocity = {};
        return;
    }
    if (after / energy_limit > 1.01) {
        const double scale = std::sqrt(energy_limit / after) * std::sqrt(1.01);
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
            {},
            0.0,
            0,
    };
}

void resolve_contact(RigidBodyState &state, const CollisionContact &contact, const SimulationConfig &config) {
    const Vec3 normal = normalized_or_zero(contact.normal);
    const double normal_speed = dot(state.velocity, normal);
    if (contact.has_resolved_state && finite(contact.resolved_velocity) && finite(contact.resolved_angular_velocity)) {
        state.velocity = contact.resolved_velocity;
        state.angular_velocity = contact.resolved_angular_velocity;
    } else if (finite(contact.impulse) && length(contact.impulse) > 0.0 && config.mass_kg > 0.0) {
        state.velocity = state.velocity + contact.impulse * (1.0 / config.mass_kg);
    } else if (normal_speed < 0.0) {
        const double restitution = std::clamp(contact.restitution, 0.0, 1.0);
        state.velocity = state.velocity - normal * ((1.0 + restitution) * normal_speed);
    }

    sanitize(state.velocity);
    sanitize(state.angular_velocity);

    clamp_energy(state, config, contact.max_kinetic_energy_joules);
}

} // namespace

bool valid_collision_contact(const CollisionContact &contact) {
    return finite(contact.normal) && finite(contact.impulse) && std::isfinite(contact.restitution) &&
            contact.restitution >= 0.0 && contact.restitution <= 1.0 &&
            finite(contact.resolved_velocity) && finite(contact.resolved_angular_velocity) &&
            std::isfinite(contact.max_kinetic_energy_joules);
}

double kinetic_energy_joules(const RigidBodyState &state, const SimulationConfig &config) {
    const Vec3 inertia_frd = config.per_motor.inertia_kg_m2;
    if (!std::isfinite(config.mass_kg) || config.mass_kg <= 0.0 ||
            !std::isfinite(inertia_frd.x) || !std::isfinite(inertia_frd.y) || !std::isfinite(inertia_frd.z) ||
            inertia_frd.x <= 0.0 || inertia_frd.y <= 0.0 || inertia_frd.z <= 0.0 ||
            !finite(state.velocity) || !finite(state.angular_velocity)) {
        return std::numeric_limits<double>::infinity();
    }
    const Vec3 angular_velocity_frd = y_up_to_frd(state.angular_velocity);
    const double linear = 0.5 * config.mass_kg * dot(state.velocity, state.velocity);
    const double angular = 0.5 * (
            inertia_frd.x * angular_velocity_frd.x * angular_velocity_frd.x +
            inertia_frd.y * angular_velocity_frd.y * angular_velocity_frd.y +
            inertia_frd.z * angular_velocity_frd.z * angular_velocity_frd.z);
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
    return try_step(state, clock, controller, config, command, contact, state.orientation);
}

CollisionStepResult CollisionAuthoritySwitch::step(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const FlightCommand &command,
        const CollisionContact &contact,
        const Quat &estimated_attitude) {
    return try_step(state, clock, controller, config, command, contact, estimated_attitude);
}

CollisionStepResult CollisionAuthoritySwitch::try_step(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const FlightCommand &command,
        const CollisionContact &contact,
        const Quat &estimated_attitude) {
    if (!valid_collision_contact(contact)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidCommand};
    }
    if (!valid_command(command)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidCommand};
    }
    if (!valid_config(config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidConfig};
    }
    if (!valid_state(state) || !valid_clock(clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidState};
    }
    if (!finite(estimated_attitude)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidState};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    FlightController staged_controller = controller;
    CollisionAuthoritySwitch staged_authority = *this;
    CollisionStepResult result = staged_authority.step_impl(
            staged_state, staged_clock, staged_controller, config, command, contact, estimated_attitude);
    if (result.status != StepStatus::Ok || !valid_state(staged_state) || !valid_clock(staged_clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidControlOutput};
    }
    state = staged_state;
    clock = staged_clock;
    controller = std::move(staged_controller);
    *this = staged_authority;
    result.status = StepStatus::Ok;
    return result;
}

CollisionStepResult CollisionAuthoritySwitch::step_impl(
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
        resolve_contact(state, contact, config);

        return {authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }

    const StepResult controller_result = controller.try_step_angle_mode(state, clock, config, command, estimated_attitude);
    return {authority_, controller_result.sample, {}, {}, controller_result.status};
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
    return try_step_altitude_hold(state, clock, controller, config, command, measured_altitude_m, contact, estimated_attitude);
}

CollisionStepResult CollisionAuthoritySwitch::try_step_altitude_hold(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const FlightCommand &command,
        double measured_altitude_m,
        const CollisionContact &contact,
        const Quat &estimated_attitude) {
    if (!valid_collision_contact(contact) || !valid_command(command)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidCommand};
    }
    if (!valid_config(config) || !std::isfinite(measured_altitude_m)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidConfig};
    }
    if (!valid_state(state) || !valid_clock(clock, config) || !finite(estimated_attitude)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidState};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    FlightController staged_controller = controller;
    CollisionAuthoritySwitch staged_authority = *this;
    CollisionStepResult result = staged_authority.step_altitude_hold_impl(
            staged_state, staged_clock, staged_controller, config, command, measured_altitude_m, contact, estimated_attitude);
    if (result.status != StepStatus::Ok || !valid_state(staged_state) || !valid_clock(staged_clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidControlOutput};
    }
    state = staged_state;
    clock = staged_clock;
    controller = std::move(staged_controller);
    *this = staged_authority;
    return result;
}

CollisionStepResult CollisionAuthoritySwitch::step_altitude_hold_impl(
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
        resolve_contact(state, contact, config);

        return {authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }

    const StepResult controller_result = controller.try_step_altitude_hold_mode(
            state, clock, config, command, measured_altitude_m, estimated_attitude);
    return {authority_, controller_result.sample, {}, {}, controller_result.status};
}

CollisionStepResult CollisionAuthoritySwitch::step_acro(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const AcroCommand &command,
        const CollisionContact &contact) {
    return try_step_acro(state, clock, controller, config, command, contact);
}

CollisionStepResult CollisionAuthoritySwitch::try_step_acro(
        RigidBodyState &state,
        SimulationClock &clock,
        FlightController &controller,
        const SimulationConfig &config,
        const AcroCommand &command,
        const CollisionContact &contact) {
    if (!valid_collision_contact(contact) || !valid_command(command)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidCommand};
    }
    if (!valid_config(config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidConfig};
    }
    if (!valid_state(state) || !valid_clock(clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidState};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    FlightController staged_controller = controller;
    CollisionAuthoritySwitch staged_authority = *this;
    CollisionStepResult result = staged_authority.step_acro_impl(
            staged_state, staged_clock, staged_controller, config, command, contact);
    if (result.status != StepStatus::Ok || !valid_state(staged_state) || !valid_clock(staged_clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidControlOutput};
    }
    state = staged_state;
    clock = staged_clock;
    controller = std::move(staged_controller);
    *this = staged_authority;
    return result;
}

CollisionStepResult CollisionAuthoritySwitch::step_acro_impl(
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
        resolve_contact(state, contact, config);

        return {authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
    }

    if (authority_ == PhysicsAuthority::Jolt) {
        ++clear_frames_;
        if (clear_frames_ < release_frames_) {
            return {authority_, sample_jolt_frame(state, clock, config), {}, {}};
        }
        authority_ = PhysicsAuthority::FlightCore;
    }

    const StepResult controller_result = controller.try_step_acro_mode(state, clock, config, command);
    return {authority_, controller_result.sample, {}, {}, controller_result.status};
}

CollisionStepResult CollisionAuthoritySwitch::step_per_motor(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const MotorCommands &commands,
        const CollisionContact &contact) {
    return try_step_per_motor(state, clock, config, commands, contact);
}

CollisionStepResult CollisionAuthoritySwitch::try_step_per_motor(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const MotorCommands &commands,
        const CollisionContact &contact) {
    if (!valid_collision_contact(contact) || !valid_commands(commands)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidCommand};
    }
    if (!valid_config(config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidConfig};
    }
    if (!valid_state(state) || !valid_clock(clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidState};
    }
    RigidBodyState staged_state = state;
    SimulationClock staged_clock = clock;
    CollisionAuthoritySwitch staged_authority = *this;
    CollisionStepResult result = staged_authority.step_per_motor_impl(
            staged_state, staged_clock, config, commands, contact);
    if (result.status != StepStatus::Ok || !valid_state(staged_state) || !valid_clock(staged_clock, config)) {
        return {authority_, {}, {}, {}, StepStatus::InvalidControlOutput};
    }
    state = staged_state;
    clock = staged_clock;
    *this = staged_authority;
    return result;
}

CollisionStepResult CollisionAuthoritySwitch::step_per_motor_impl(
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
        resolve_contact(state, contact, config);
        return {authority_, sample_jolt_frame(state, clock, config), contact.normal, contact.impulse};
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
