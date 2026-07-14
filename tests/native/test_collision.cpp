#include "aerosim_collision.hpp"

#include <array>
#include <cstdint>
#include <cstring>
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
            same_bits(a.angular_velocity.z, b.angular_velocity.z);
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
    std::uint64_t substeps = 0;
};

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

    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    aerosim::AcroCommand acro_hover;
    acro_hover.throttle = 0.5;
    acro_hover.rates = {1.0, 0.7, 0.0};
    const double kinetic_before = aerosim::kinetic_energy_joules(state, config.mass_kg);
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
    if (aerosim::kinetic_energy_joules(state, config.mass_kg) > kinetic_before * 1.01) {
        return {};
    }

    aerosim::CollisionContact clear;
    aerosim::FlightCommand recover;
    recover.throttle = 0.8;
    recover.roll_degrees = 3.0;
    recover.pitch_degrees = -2.0;
    recover.yaw_rate_degrees_per_second = 45.0;
    aerosim::AcroCommand acro_recover;
    acro_recover.throttle = 0.8;
    acro_recover.roll_stick = 0.1;
    acro_recover.pitch_stick = -0.1;
    acro_recover.yaw_stick = 0.1;
    acro_recover.rates = {1.0, 0.7, 0.0};

    for (int frame = 0; frame < authority.release_frames(); ++frame) {
        step_trial_mode(mode, authority, state, clock, controller, config, recover, acro_recover, clear);
    }
    if (authority.current_authority() != aerosim::PhysicsAuthority::FlightCore) {
        return {};
    }

    const double y_before_response = state.position.y;
    const aerosim::Vec3 angular_before_response = state.angular_velocity;
    for (int frame = 0; frame < config.physics_hz / 2; ++frame) {
        step_trial_mode(mode, authority, state, clock, controller, config, recover, acro_recover, clear);
    }
    const double angular_response =
            std::abs(state.angular_velocity.x - angular_before_response.x) +
            std::abs(state.angular_velocity.y - angular_before_response.y) +
            std::abs(state.angular_velocity.z - angular_before_response.z);
    if ((mode == ControlMode::Angle && state.position.y <= y_before_response) ||
            (mode == ControlMode::Acro && angular_response <= 1e-6) || !finite(state)) {
        return {};
    }

    return {state, clock.total_substeps};
}

} // namespace

int main() {
    aerosim::SimulationConfig config;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

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

    aerosim::CollisionContact wall;
    wall.touching = true;
    wall.normal = {-1.0, 0.0, 0.0};
    wall.restitution = 0.0;

    const double kinetic_before = aerosim::kinetic_energy_joules(state, config.mass_kg);
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
    if (aerosim::kinetic_energy_joules(state, config.mass_kg) > kinetic_before * 1.01) {
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
    if (aerosim::kinetic_energy_joules(clamped_state, config.mass_kg) > energetic_contact.max_kinetic_energy_joules * 1.01) {
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
                const TrialResult second = run_trial(scenario, seed, mode);
                if (first.substeps == 0 || second.substeps == 0) {
                    return fail("G0.8 randomized collision scenario failed its authority/energy/response contract");
                }
                if (first.substeps != second.substeps || !same_state_bits(first.final_state, second.final_state)) {
                    return fail("G0.8 same-seed collision replay must be bitwise deterministic");
                }
            }
        }
    }

    return EXIT_SUCCESS;
}
