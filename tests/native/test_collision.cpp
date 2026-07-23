#include "aerosim_collision.hpp"
#include "aerosim_replay.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <cfloat>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool finite(const aerosim::Vec3 &v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

bool finite(const aerosim::Quat &q) {
    return std::isfinite(q.x) && std::isfinite(q.y) && std::isfinite(q.z) && std::isfinite(q.w);
}

bool finite(const aerosim::RigidBodyState &state) {
    return finite(state.position) &&
            finite(state.velocity) &&
            finite(state.orientation) &&
            finite(state.angular_velocity);
}

bool same_bits(double a, double b) {
    return std::memcmp(&a, &b, sizeof(double)) == 0;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

double vector_length(const aerosim::Vec3 &value) {
    return std::sqrt(value.x * value.x + value.y * value.y + value.z * value.z);
}

void configure_power_model(aerosim::SimulationConfig &config) {
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = config.mass_kg * config.gravity_mps2 * 2.0;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.battery_cell_resistance_ohm = 0.0;
    config.max_total_current_a = 1.0;
    config.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    config.per_motor.max_thrust_per_motor_newtons = config.max_total_thrust_newtons / 4.0;
    config.per_motor.max_current_per_motor_a = 1.0 / 4.0;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    config.a6_propwash.enabled = true;
    config.a6_propwash.full_collective_angular_accel_rad_s2 = 12.0;
    config.a6_propwash.minimum_wake_entry_speed_mps = 0.001;
    config.a6_propwash.minimum_transverse_rate_rad_s = 0.001;
}

bool same_state_bits(const aerosim::RigidBodyState &a, const aerosim::RigidBodyState &b) {
    return same_bits(a.position.x, b.position.x) &&
            same_bits(a.position.y, b.position.y) &&
            same_bits(a.position.z, b.position.z) &&
            same_bits(a.velocity.x, b.velocity.x) &&
            same_bits(a.velocity.y, b.velocity.y) &&
            same_bits(a.velocity.z, b.velocity.z) &&
            same_bits(a.orientation.x, b.orientation.x) &&
            same_bits(a.orientation.y, b.orientation.y) &&
            same_bits(a.orientation.z, b.orientation.z) &&
            same_bits(a.orientation.w, b.orientation.w) &&
            same_bits(a.angular_velocity.x, b.angular_velocity.x) &&
            same_bits(a.angular_velocity.y, b.angular_velocity.y) &&
            same_bits(a.angular_velocity.z, b.angular_velocity.z) &&
            same_bits(a.propwash_disturbance_rad_s2.x, b.propwash_disturbance_rad_s2.x) &&
            same_bits(a.propwash_disturbance_rad_s2.y, b.propwash_disturbance_rad_s2.y) &&
            same_bits(a.propwash_disturbance_rad_s2.z, b.propwash_disturbance_rad_s2.z) &&
            same_bits(a.motor_thrust_newtons[0], b.motor_thrust_newtons[0]) &&
            same_bits(a.motor_thrust_newtons[1], b.motor_thrust_newtons[1]) &&
            same_bits(a.motor_thrust_newtons[2], b.motor_thrust_newtons[2]) &&
            same_bits(a.motor_thrust_newtons[3], b.motor_thrust_newtons[3]);
}

bool same_sample_bits(const aerosim::TrajectorySample &a, const aerosim::TrajectorySample &b) {
    return same_bits(a.time_seconds, b.time_seconds) &&
            same_state_bits(a.state, b.state) &&
            a.substeps == b.substeps &&
            same_bits(a.propwash_disturbance_rad_s2.x, b.propwash_disturbance_rad_s2.x) &&
            same_bits(a.propwash_disturbance_rad_s2.y, b.propwash_disturbance_rad_s2.y) &&
            same_bits(a.propwash_disturbance_rad_s2.z, b.propwash_disturbance_rad_s2.z);
}

class Lcg {
private:
    std::uint32_t state_;

public:
    explicit Lcg(std::uint32_t seed) : state_(seed) {}

    double next(double low, double high) {
        state_ = state_ * 1664525u + 1013904223u;
        const double unit = static_cast<double>(state_ >> 8) / static_cast<double>(0x00ffffffu);
        return low + (high - low) * unit;
    }
};

enum class Scenario {
    Wall,
    GlancingGround,
    PoleBounce,
    TumbleGround,
};

enum class ControlMode {
    Angle,
    Acro,
};

struct TrialSetup {
    aerosim::RigidBodyState state;
    aerosim::CollisionContact contact;
};

struct TrialResult {
    aerosim::RigidBodyState final_state;
    aerosim::TrajectorySample first_response;
    std::uint64_t substeps = 0;
    aerosim::ReplaySession replay;
};

bool finite(const aerosim::FlightControlState &state) {
    return finite(state.target_angle_frd) && finite(state.target_rate_frd) && finite(state.previous_rate_error_frd) &&
            finite(state.filtered_rate_derivative_frd) && std::isfinite(state.motor_thrust_newtons) &&
            std::all_of(state.rate_integral.begin(), state.rate_integral.end(), [](double value) { return std::isfinite(value); });
}

bool within_configured_control_bounds(
        const aerosim::RigidBodyState &state,
        const aerosim::FlightControlState &controller,
        const aerosim::SimulationConfig &config) {
    return controller.motor_thrust_newtons >= 0.0 &&
            controller.motor_thrust_newtons <= config.max_total_thrust_newtons &&
            std::all_of(state.motor_thrust_newtons.begin(), state.motor_thrust_newtons.end(), [&config](double thrust) {
                return thrust >= 0.0 && thrust <= config.per_motor.max_thrust_per_motor_newtons;
            });
}

TrialSetup setup_trial(Scenario scenario, std::uint32_t seed) {
    constexpr double kPi = 3.14159265358979323846;
    Lcg rng(seed);
    TrialSetup setup;

    if (scenario == Scenario::Wall) {
        setup.state.velocity = {30.0 + rng.next(-0.25, 0.25), rng.next(-0.1, 0.1), rng.next(-0.1, 0.1)};
        setup.contact.normal = {-1.0, 0.0, 0.0};
    } else if (scenario == Scenario::GlancingGround) {
        const double speed = 20.0 + rng.next(-0.5, 0.5);
        setup.state.velocity = {speed * std::cos(5.0 * kPi / 180.0), -speed * std::sin(5.0 * kPi / 180.0), rng.next(-0.1, 0.1)};
        setup.contact.normal = {0.0, 1.0, 0.0};
        setup.contact.restitution = 0.1;
    } else if (scenario == Scenario::PoleBounce) {
        const double theta = rng.next(-0.25, 0.25);
        setup.state.velocity = {14.0 * std::cos(theta), rng.next(-0.1, 0.1), 14.0 * std::sin(theta)};
        setup.contact.normal = {-std::cos(theta), 0.0, -std::sin(theta)};
        setup.contact.restitution = 0.35;
    } else {
        setup.state.velocity = {rng.next(-2.0, 2.0), -8.0 + rng.next(-0.5, 0.5), rng.next(-2.0, 2.0)};
        setup.state.angular_velocity = {rng.next(-9.0, 9.0), rng.next(-9.0, 9.0), rng.next(-9.0, 9.0)};
        setup.state.orientation = {1.0, 0.0, 0.0, 0.0};
        setup.contact.normal = {0.0, 1.0, 0.0};
        setup.contact.restitution = 0.2;
    }
    setup.contact.touching = true;
    return setup;
}

aerosim::CollisionStepResult step_trial_mode(
        ControlMode mode,
        aerosim::CollisionAuthoritySwitch &authority,
        aerosim::RigidBodyState &state,
        aerosim::SimulationClock &clock,
        aerosim::FlightController &controller,
        const aerosim::SimulationConfig &config,
        const aerosim::FlightCommand &angle_command,
        const aerosim::AcroCommand &acro_command,
        const aerosim::CollisionContact &contact) {
    if (mode == ControlMode::Acro) {
        return authority.step_acro(state, clock, controller, config, acro_command, contact);
    }
    return authority.step(state, clock, controller, config, angle_command, contact);
}

TrialResult run_trial(Scenario scenario, std::uint32_t seed, ControlMode mode) {
    aerosim::SimulationConfig config;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

    TrialSetup setup = setup_trial(scenario, seed);
    aerosim::RigidBodyState state = setup.state;
    aerosim::SimulationClock clock;
    aerosim::FlightController controller;
    controller.arm(0.0);
    aerosim::CollisionAuthoritySwitch authority;
    authority.set_release_frames(1);

    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    aerosim::AcroCommand acro_hover;
    acro_hover.throttle = 0.5;
    acro_hover.rates = {1.0, 0.7, 0.0};
    const double kinetic_before = aerosim::kinetic_energy_joules(state, config);
    const aerosim::CollisionStepResult impact = step_trial_mode(
            mode,
            authority,
            state,
            clock,
            controller,
            config,
            hover,
            acro_hover,
            setup.contact);
    if (impact.authority != aerosim::PhysicsAuthority::Jolt) {
        return {};
    }
    if (controller.integrator_reset_count() != 1) {
        return {};
    }
    if (!finite(state)) {
        return {};
    }
    if (aerosim::kinetic_energy_joules(state, config) > kinetic_before * 1.01) {
        return {};
    }

    aerosim::CollisionContact clear;
    aerosim::FlightCommand neutral;
    neutral.throttle = 0.5;
    aerosim::AcroCommand acro_neutral;
    acro_neutral.throttle = 0.5;
    acro_neutral.rates = {1.0, 0.7, 0.0};
    aerosim::FlightCommand response;
    response.throttle = 0.8;
    response.roll_degrees = 3.0;
    response.pitch_degrees = -2.0;
    response.yaw_rate_degrees_per_second = 45.0;
    aerosim::AcroCommand acro_response;
    acro_response.throttle = 0.8;
    acro_response.roll_stick = 0.1;
    acro_response.pitch_stick = 0.1;
    acro_response.yaw_stick = 0.1;
    acro_response.rates = {1.0, 0.7, 0.0};

    for (int frame = 0; frame < authority.release_frames(); ++frame) {
        step_trial_mode(mode, authority, state, clock, controller, config, neutral, acro_neutral, clear);
    }
    if (authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
        return {};
    }

    const aerosim::RigidBodyState ready_state = state;
    const aerosim::SimulationClock ready_clock = clock;
    const aerosim::FlightControlState ready_controller = controller.control_state();

    aerosim::RigidBodyState neutral_state = state;
    aerosim::SimulationClock neutral_clock = clock;
    aerosim::FlightController neutral_controller = controller;
    aerosim::CollisionAuthoritySwitch neutral_authority = authority;
    aerosim::RigidBodyState response_state = state;
    aerosim::SimulationClock response_clock = clock;
    aerosim::FlightController response_controller = controller;
    aerosim::CollisionAuthoritySwitch response_authority = authority;
    aerosim::TrajectorySample first_response;
    bool has_first_response = false;
    std::uint64_t response_frames = 0;
    const std::uint64_t response_start = response_clock.total_substeps;
    while (response_clock.total_substeps - response_start < 500) {
        const aerosim::CollisionStepResult neutral_step = step_trial_mode(
                mode, neutral_authority, neutral_state, neutral_clock, neutral_controller, config, neutral, acro_neutral, clear);
        const aerosim::CollisionStepResult response_step = step_trial_mode(
                mode, response_authority, response_state, response_clock, response_controller, config, response, acro_response, clear);
        if (neutral_step.authority != aerosim::PhysicsAuthority::FlightCore ||
                response_step.authority != aerosim::PhysicsAuthority::FlightCore || !finite(neutral_state) || !finite(response_state) ||
                !finite(neutral_controller.control_state()) || !finite(response_controller.control_state()) ||
                !within_configured_control_bounds(neutral_state, neutral_controller.control_state(), config) ||
                !within_configured_control_bounds(response_state, response_controller.control_state(), config)) {
            return {};
        }
        if (!has_first_response) {
            first_response = response_step.sample;
            if (response_step.sample.first_substeps > 0) {
                first_response.time_seconds = response_step.sample.first_substep_time_seconds;
                first_response.state = response_step.sample.first_substep_state;
                first_response.substeps = response_step.sample.first_substeps;
            }
            has_first_response = true;
        }
        ++response_frames;
    }
    const double epsilon = 64.0 * DBL_EPSILON * std::max(1.0, config.per_motor.max_thrust_per_motor_newtons);
    bool motor_responded = false;
    for (std::size_t motor = 0; motor < response_state.motor_thrust_newtons.size(); ++motor) {
        motor_responded = motor_responded || std::abs(response_state.motor_thrust_newtons[motor] -
                neutral_state.motor_thrust_newtons[motor]) > epsilon;
    }
    if (!motor_responded) {
        return {};
    }
    if (scenario == Scenario::TumbleGround && vector_length(first_response.state.propwash_disturbance_rad_s2) <= 0.0) {
        return {};
    }
    aerosim::ReplaySessionRecorder recorder(seed, "collision-recovery");
    const std::string atmosphere =
            "{\"atmosphere\":{\"preset\":\"calm\",\"steady_wind\":[0,0,0],\"turbulence_sigma\":[0,0,0],"
            "\"reference_airspeed_mps\":30,\"scale_length_m\":200,\"shear_reference_height_m\":1,"
            "\"shear_exponent\":1,\"shear_enabled\":false,\"seed\":1},\"atmosphere_air_density_kg_m3\":1.225}";
    aerosim::DualAircraftConfig replay_config;
    replay_config.upper = config;
    replay_config.upper.initial_state = setup.state;
    replay_config.lower = config;
    aerosim::FlightController inactive_controller;
    inactive_controller.arm(0.0);
    aerosim::ReplayRunCheckpoint checkpoint;
    checkpoint.state = {response_state, replay_config.lower.initial_state};
    checkpoint.controllers = {{response_controller.control_state(), inactive_controller.control_state()}};
    checkpoint.clocks[0] = response_clock;
    checkpoint.first_response_substeps[0] = first_response;
    aerosim::ReplayRunCheckpoint ready_checkpoint;
    ready_checkpoint.state = {ready_state, replay_config.lower.initial_state};
    ready_checkpoint.controllers = {{ready_controller, inactive_controller.control_state()}};
    ready_checkpoint.clocks[0] = ready_clock;
    const std::string vehicle_config = "{\"mass_kg\":1.0,\"physics_hz\":240,\"substep_hz\":1000}";
    if (!recorder.add_vehicle("DroneA", "hash-a", vehicle_config) ||
            !recorder.add_vehicle("DroneB", "hash-b", vehicle_config) ||
            !recorder.record_environment(0, atmosphere) ||
            !recorder.record_mode_command(0, "DroneA",
                    mode == ControlMode::Acro ? aerosim::ReplayCommandMode::Acro : aerosim::ReplayCommandMode::Angle,
                    hover, acro_hover, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_collision(0, "DroneA", setup.contact, aerosim::ReplayControllerAuthority::Jolt) ||
            !recorder.record_simulation_operation(0, aerosim::ReplaySimulationOperation::StepFrames, 1.0) ||
            !recorder.record_mode_command(1, "DroneA",
                    mode == ControlMode::Acro ? aerosim::ReplayCommandMode::Acro : aerosim::ReplayCommandMode::Angle,
                    neutral, acro_neutral, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_simulation_operation(1, aerosim::ReplaySimulationOperation::StepFrames,
                    static_cast<double>(authority.release_frames())) ||
            !recorder.record_checkpoint(1, ready_checkpoint) ||
            !recorder.record_mode_command(2, "DroneA",
                    mode == ControlMode::Acro ? aerosim::ReplayCommandMode::Acro : aerosim::ReplayCommandMode::Angle,
                    response, acro_response, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_simulation_operation(2, aerosim::ReplaySimulationOperation::StepFrames,
                    static_cast<double>(response_frames)) ||
            !recorder.record_checkpoint(2, checkpoint) || !recorder.finish(2, "completed")) {
        return {};
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(recorder.serialize(), "collision-recovery");
    if (!loaded.ok || aerosim::compare_replay_sessions(recorder.session(), loaded.session).diverged ||
            !same_sample_bits(loaded.session.checkpoints[1].first_response_substeps[0], first_response)) {
        return {};
    }
    const aerosim::ReplayRunResult replayed = aerosim::replay_session(
            loaded.session, replay_config, "collision-recovery", {{"hash-a", "hash-b"}});
    const bool same_ready = replayed.checkpoints.size() == 2 &&
            same_state_bits(replayed.checkpoints[0].state.upper, ready_state);
    const bool same_final = same_state_bits(replayed.final_state.upper, response_state);
    const bool same_checkpoint = replayed.checkpoints.size() == 2 &&
            same_state_bits(replayed.checkpoints[1].state.upper, response_state);
    const bool same_first_response = replayed.checkpoints.size() == 2 &&
            same_sample_bits(replayed.checkpoints[1].first_response_substeps[0], first_response);
    if (!replayed.ok || replayed.checkpoints.size() != 2 || !same_ready || !same_final ||
            replayed.final_clock.total_substeps != response_clock.total_substeps || !same_checkpoint || !same_first_response) {
        return {};
    }
    return {response_state, first_response, response_clock.total_substeps, loaded.session};
}

} // namespace

int main() {
    aerosim::SimulationConfig config;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

    aerosim::RigidBodyState configured_energy_state;
    configured_energy_state.velocity = {3.0, 0.0, 0.0};
    configured_energy_state.angular_velocity = {1.0, 2.0, 3.0};
    const double configured_energy_expected = 0.5 * (
            config.mass_kg * 9.0 +
            config.per_motor.inertia_kg_m2.x * 1.0 +
            config.per_motor.inertia_kg_m2.z * 4.0 +
            config.per_motor.inertia_kg_m2.y * 9.0);
    if (!near(aerosim::kinetic_energy_joules(configured_energy_state, config), configured_energy_expected, 1e-12)) {
        return fail("collision energy must use configured mass and axis-mapped inertia");
    }
    aerosim::SimulationConfig heavier_config = config;
    heavier_config.mass_kg *= 2.0;
    aerosim::SimulationConfig higher_inertia_config = config;
    higher_inertia_config.per_motor.inertia_kg_m2.z *= 2.0;
    if (!(aerosim::kinetic_energy_joules(configured_energy_state, heavier_config) > configured_energy_expected &&
            aerosim::kinetic_energy_joules(configured_energy_state, higher_inertia_config) > configured_energy_expected)) {
        return fail("collision energy must change with configured mass and inertia");
    }

    aerosim::RigidBodyState state;
    state.velocity = {30.0, 0.0, 0.0};

    aerosim::SimulationClock clock;
    aerosim::FlightController controller;
    if (!controller.arm(0.0)) {
        return fail("collision test setup should arm from low throttle");
    }

    aerosim::CollisionAuthoritySwitch authority;
    aerosim::FlightCommand hover;
    hover.throttle = 0.5;

    const aerosim::RigidBodyState state_before_invalid_contact = state;
    const aerosim::SimulationClock clock_before_invalid_contact = clock;
    aerosim::CollisionContact atomic_invalid_contact;
    atomic_invalid_contact.touching = true;
    atomic_invalid_contact.normal.x = NAN;
    const aerosim::CollisionStepResult invalid_contact_result = authority.try_step(
            state, clock, controller, config, hover, atomic_invalid_contact);
    if (invalid_contact_result.status != aerosim::StepStatus::InvalidCommand ||
            !same_state_bits(state, state_before_invalid_contact) ||
            clock.total_substeps != clock_before_invalid_contact.total_substeps) {
        return fail("invalid collision inputs must be rejected without changing flight state");
    }

    aerosim::SimulationConfig invalid_mass_config = config;
    invalid_mass_config.mass_kg = NAN;
    aerosim::CollisionContact valid_impact;
    valid_impact.touching = true;
    valid_impact.normal = {-1.0, 0.0, 0.0};
    const aerosim::RigidBodyState state_before_invalid_mass = state;
    const aerosim::SimulationClock clock_before_invalid_mass = clock;
    const aerosim::PhysicsAuthority authority_before_invalid_mass = authority.current_authority();
    const aerosim::CollisionStepResult invalid_mass_result = authority.try_step(
            state, clock, controller, invalid_mass_config, hover, valid_impact);
    if (invalid_mass_result.status != aerosim::StepStatus::InvalidConfig ||
            !same_state_bits(state, state_before_invalid_mass) ||
            !same_bits(clock.substep_accumulator, clock_before_invalid_mass.substep_accumulator) ||
            clock.total_substeps != clock_before_invalid_mass.total_substeps ||
            authority.current_authority() != authority_before_invalid_mass) {
        return fail("invalid collision config must not mutate contact state, clock, or authority");
    }

    aerosim::SimulationConfig sparse_frame_config = config;
    sparse_frame_config.physics_hz = 1000;
    sparse_frame_config.substep_hz = 240;
    aerosim::RigidBodyState sparse_frame_state;
    aerosim::SimulationClock sparse_frame_clock;
    aerosim::FlightController sparse_frame_controller;
    aerosim::CollisionAuthoritySwitch sparse_frame_authority;
    if (!sparse_frame_controller.arm(0.0)) {
        return fail("sparse-frame collision setup should arm from low throttle");
    }
    const aerosim::CollisionStepResult sparse_frame_result = sparse_frame_authority.try_step(
            sparse_frame_state, sparse_frame_clock, sparse_frame_controller, sparse_frame_config, hover, {});
    if (sparse_frame_result.status != aerosim::StepStatus::InvalidConfig || sparse_frame_result.sample.substeps != 0 ||
            sparse_frame_authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
        return fail("an unschedulable frame must be rejected without changing collision authority");
    }

    aerosim::SimulationConfig invalid_rate_config = config;
    invalid_rate_config.physics_hz = 0;
    aerosim::CollisionContact invalid_contact;
    invalid_contact.touching = true;
    const aerosim::RigidBodyState state_before_invalid_rate = state;
    const aerosim::CollisionStepResult invalid_rate_result = authority.step(
            state,
            clock,
            controller,
            invalid_rate_config,
            hover,
            invalid_contact);
    if (invalid_rate_result.sample.substeps != 0 || clock.total_substeps != 0 ||
            !same_state_bits(state, state_before_invalid_rate) ||
            invalid_rate_result.authority != aerosim::PhysicsAuthority::FlightCore) {
        return fail("collision paths must fail closed before touching contact state for invalid rates");
    }
    aerosim::AcroCommand invalid_acro_command;
    invalid_acro_command.throttle = 0.5;
    aerosim::MotorCommands invalid_motor_commands;
    const aerosim::CollisionStepResult invalid_altitude_result = authority.step_altitude_hold(
            state,
            clock,
            controller,
            invalid_rate_config,
            hover,
            0.0,
            invalid_contact,
            aerosim::Quat{});
    const aerosim::CollisionStepResult invalid_acro_result = authority.step_acro(
            state,
            clock,
            controller,
            invalid_rate_config,
            invalid_acro_command,
            invalid_contact);
    const aerosim::CollisionStepResult invalid_per_motor_result = authority.step_per_motor(
            state,
            clock,
            invalid_rate_config,
            invalid_motor_commands,
            invalid_contact);
    if (invalid_altitude_result.sample.substeps != 0 || invalid_acro_result.sample.substeps != 0 ||
            invalid_per_motor_result.sample.substeps != 0 || clock.total_substeps != 0 ||
            !same_state_bits(state, state_before_invalid_rate) ||
            invalid_altitude_result.authority != aerosim::PhysicsAuthority::FlightCore ||
            invalid_acro_result.authority != aerosim::PhysicsAuthority::FlightCore ||
            invalid_per_motor_result.authority != aerosim::PhysicsAuthority::FlightCore) {
        return fail("all collision variants must fail closed before touching state or authority for invalid rates");
    }

    aerosim::SimulationClock variant_clock;
    aerosim::RigidBodyState variant_state;
    aerosim::FlightController variant_controller;
    aerosim::CollisionAuthoritySwitch variant_authority;
    if (!variant_controller.arm(0.0)) {
        return fail("collision variant atomic setup should arm from low throttle");
    }
    aerosim::CollisionContact invalid_variant_contact;
    invalid_variant_contact.touching = true;
    invalid_variant_contact.normal.x = NAN;
    aerosim::AcroCommand valid_acro;
    valid_acro.throttle = 0.5;
    aerosim::MotorCommands valid_motors{{0.5, 0.5, 0.5, 0.5}};
    const aerosim::RigidBodyState variant_state_before = variant_state;
    const aerosim::SimulationClock variant_clock_before = variant_clock;
    const aerosim::CollisionStepResult invalid_variant_altitude = variant_authority.step_altitude_hold(
            variant_state, variant_clock, variant_controller, config, hover, 0.0, invalid_variant_contact, {});
    const aerosim::CollisionStepResult invalid_variant_acro = variant_authority.step_acro(
            variant_state, variant_clock, variant_controller, config, valid_acro, invalid_variant_contact);
    const aerosim::CollisionStepResult invalid_variant_motor = variant_authority.step_per_motor(
            variant_state, variant_clock, config, valid_motors, invalid_variant_contact);
    if (invalid_variant_altitude.status != aerosim::StepStatus::InvalidCommand ||
            invalid_variant_acro.status != aerosim::StepStatus::InvalidCommand ||
            invalid_variant_motor.status != aerosim::StepStatus::InvalidCommand ||
            !same_state_bits(variant_state, variant_state_before) ||
            variant_clock.total_substeps != variant_clock_before.total_substeps ||
            variant_authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
        return fail("invalid collision variants must retain FlightCore state and report InvalidCommand");
    }
    for (const aerosim::RateProfile invalid_rates : {
                 aerosim::RateProfile{-0.1, 0.7, 0.0}, aerosim::RateProfile{3.1, 0.7, 0.0},
                 aerosim::RateProfile{1.0, -0.1, 0.0}, aerosim::RateProfile{1.0, 1.1, 0.0},
                 aerosim::RateProfile{1.0, 0.7, -0.1}, aerosim::RateProfile{1.0, 0.7, 1.1},
         }) {
        valid_acro.rates = invalid_rates;
        const aerosim::CollisionStepResult invalid_tuning = variant_authority.step_acro(
                variant_state, variant_clock, variant_controller, config, valid_acro, {});
        if (invalid_tuning.status != aerosim::StepStatus::InvalidCommand ||
                !same_state_bits(variant_state, variant_state_before) ||
                variant_clock.total_substeps != variant_clock_before.total_substeps ||
                variant_authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
            return fail("collision Acro rate profiles outside the public bounds must fail closed");
        }
    }
    valid_acro.rates = {1.0, 0.0, 0.0};
    aerosim::RigidBodyState untouched_state = variant_state_before;
    aerosim::SimulationClock untouched_clock = variant_clock_before;
    aerosim::FlightController untouched_controller = variant_controller;
    aerosim::CollisionAuthoritySwitch untouched_authority;
    const aerosim::CollisionStepResult continued = variant_authority.step_acro(
            variant_state, variant_clock, variant_controller, config, valid_acro, {});
    const aerosim::CollisionStepResult untouched = untouched_authority.step_acro(
            untouched_state, untouched_clock, untouched_controller, config, valid_acro, {});
    if (continued.status != aerosim::StepStatus::Ok || untouched.status != aerosim::StepStatus::Ok ||
            !same_state_bits(variant_state, untouched_state) ||
            variant_clock.total_substeps != untouched_clock.total_substeps ||
            variant_authority.current_authority() != untouched_authority.current_authority()) {
        return fail("a legal collision variant after rejection must match an untouched continuation");
    }

    aerosim::CollisionContact wall;
    wall.touching = true;
    wall.normal = {-1.0, 0.0, 0.0};
    wall.restitution = 0.0;

    const double kinetic_before = aerosim::kinetic_energy_joules(state, config);
    const aerosim::CollisionStepResult impact = authority.step(
            state,
            clock,
            controller,
            config,
            hover,
            wall);

    if (impact.authority != aerosim::PhysicsAuthority::Jolt) {
        return fail("broadphase contact must hand authority to Jolt on the same frame");
    }
    if (controller.integrator_reset_count() != 1) {
        return fail("collision handoff must reset flight-controller integrators");
    }
    if (!finite(state)) {
        return fail("collision resolution must leave finite linear and angular velocity");
    }
    if (aerosim::kinetic_energy_joules(state, config) > kinetic_before * 1.01) {
        return fail("collision resolution must not increase kinetic energy beyond G0.8 tolerance");
    }

    aerosim::CollisionContact clear;
    aerosim::FlightCommand climb;
    climb.throttle = 0.8;

    for (int frame = 0; frame < authority.release_frames(); ++frame) {
        authority.step(state, clock, controller, config, climb, clear);
    }
    if (authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
        return fail("authority must return to flight core after the configured no-contact frames");
    }

    const double y_before_response = state.position.y;
    for (int frame = 0; frame < config.physics_hz / 2; ++frame) {
        authority.step(state, clock, controller, config, climb, clear);
    }
    if (state.position.y <= y_before_response) {
        return fail("flight control must respond to input within 0.5 seconds after handback");
    }

    aerosim::RigidBodyState jolt_state;
    jolt_state.velocity = {30.0, 0.0, 0.0};
    aerosim::SimulationClock jolt_clock;
    aerosim::FlightController jolt_controller;
    jolt_controller.arm(0.0);
    aerosim::CollisionAuthoritySwitch jolt_authority;
    aerosim::CollisionContact jolt_contact;
    jolt_contact.touching = true;
    jolt_contact.normal = {-1.0, 0.0, 0.0};
    jolt_contact.has_resolved_state = true;
    jolt_contact.resolved_velocity = {-2.0, 0.0, 0.0};
    jolt_contact.resolved_angular_velocity = {1.0, 2.0, 3.0};
    jolt_contact.impulse = {-100.0, 0.0, 0.0};
    jolt_authority.step(jolt_state, jolt_clock, jolt_controller, config, hover, jolt_contact);
    if (!same_bits(jolt_state.velocity.x, -2.0) ||
            !same_bits(jolt_state.angular_velocity.x, 1.0) ||
            !same_bits(jolt_state.angular_velocity.y, 2.0) ||
            !same_bits(jolt_state.angular_velocity.z, 3.0)) {
        return fail("collision handoff must write back Jolt-resolved velocity and angular velocity");
    }

    aerosim::RigidBodyState clamped_state;
    aerosim::SimulationClock clamped_clock;
    aerosim::FlightController clamped_controller;
    clamped_controller.arm(0.0);
    aerosim::CollisionAuthoritySwitch clamped_authority;
    aerosim::CollisionContact energetic_contact;
    energetic_contact.touching = true;
    energetic_contact.normal = {-1.0, 0.0, 0.0};
    energetic_contact.has_resolved_state = true;
    energetic_contact.resolved_velocity = {100.0, 0.0, 0.0};
    energetic_contact.max_kinetic_energy_joules = 1000.0;
    clamped_authority.step(clamped_state, clamped_clock, clamped_controller, config, hover, energetic_contact);
    if (aerosim::kinetic_energy_joules(clamped_state, config) > energetic_contact.max_kinetic_energy_joules * 1.01) {
        return fail("collision handoff must clamp externally supplied Jolt energy to G0.8 tolerance");
    }

    aerosim::RigidBodyState impulse_state;
    aerosim::SimulationClock impulse_clock;
    aerosim::FlightController impulse_controller;
    impulse_controller.arm(0.0);
    aerosim::CollisionAuthoritySwitch impulse_authority(5);
    aerosim::CollisionContact impulse_contact;
    impulse_contact.touching = true;
    impulse_contact.normal = {-1.0, 0.0, 0.0};
    impulse_contact.impulse = {-4.0, 0.0, 0.0};
    impulse_authority.step(impulse_state, impulse_clock, impulse_controller, config, hover, impulse_contact);
    if (impulse_state.velocity.x >= 0.0) {
        return fail("collision handoff must write back Jolt contact impulse when resolved state is unavailable");
    }
    for (int frame = 0; frame < 4; ++frame) {
        impulse_authority.step(impulse_state, impulse_clock, impulse_controller, config, hover, {});
    }
    if (impulse_authority.current_authority() != aerosim::PhysicsAuthority::Jolt) {
        return fail("configured release frame count must delay handback");
    }
    impulse_authority.step(impulse_state, impulse_clock, impulse_controller, config, hover, {});
    if (impulse_authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
        return fail("configured release frame count must hand back after N clear frames");
    }

    aerosim::RigidBodyState handback_state;
    const double ten_degrees = 10.0 * 3.14159265358979323846 / 180.0;
    handback_state.orientation.x = std::sin(ten_degrees * 0.5);
    handback_state.orientation.w = std::cos(ten_degrees * 0.5);
    aerosim::SimulationClock handback_clock;
    aerosim::FlightController handback_controller;
    handback_controller.arm(0.0);
    aerosim::CollisionAuthoritySwitch handback_authority(1);
    aerosim::CollisionContact handback_contact;
    handback_contact.touching = true;
    handback_contact.normal = {0.0, 1.0, 0.0};
    handback_authority.step(handback_state, handback_clock, handback_controller, config, hover, handback_contact);
    const aerosim::CollisionStepResult handback = handback_authority.step(
            handback_state,
            handback_clock,
            handback_controller,
            config,
            hover,
            {},
            aerosim::Quat{});
    if (handback.authority != aerosim::PhysicsAuthority::FlightCore) {
        return fail("collision authority must hand back to flight core on the configured clear frame");
    }
    if (!near(handback_state.angular_velocity.x, 0.0, 1e-12)) {
        return fail("collision handback Angle Mode must use IMU estimated attitude instead of true body attitude");
    }

    constexpr std::array<Scenario, 4> scenarios{
            Scenario::Wall,
            Scenario::GlancingGround,
            Scenario::PoleBounce,
            Scenario::TumbleGround,
    };
    constexpr std::array<ControlMode, 2> modes{
            ControlMode::Angle,
            ControlMode::Acro,
    };

    for (ControlMode mode : modes) {
        for (Scenario scenario : scenarios) {
            for (std::uint32_t seed = 0; seed < 100; ++seed) {
                const TrialResult first = run_trial(scenario, seed, mode);
                if (first.substeps == 0 || first.replay.schema_version != aerosim::kCompleteReplaySchemaVersion) {
                    return fail("G0.8 randomized collision scenario failed its authority/energy/response contract");
                }
            }
        }
    }

    return EXIT_SUCCESS;
}
