#include "aerosim_flight_control.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

aerosim::SimulationConfig standard_config() {
    aerosim::SimulationConfig config;
    config.mass_kg = 0.72;
    config.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    config.per_motor.max_thrust_per_motor_newtons = 8.0;
    config.per_motor.max_current_per_motor_a = 45.0;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    return config;
}

double achieved_roll(const aerosim::SimulationConfig &config, const std::array<double, 4> &normalized) {
    double roll = 0.0;
    for (std::size_t index = 0; index < normalized.size(); ++index) {
        roll -= config.per_motor.position_frd[index].y *
                normalized[index] * config.per_motor.max_thrust_per_motor_newtons;
    }
    return roll;
}

} // namespace

int main() {
    aerosim::SimulationConfig config = standard_config();
    if (!aerosim::validate_per_motor_config(config.per_motor)) {
        return fail("balanced Quad-X configuration must be accepted");
    }

    const auto equal = aerosim::quad_x_mix_thrust(config, 16.0, {0.0, 0.0, 0.0});
    if (!equal.valid || equal.collective_saturated || equal.axis_saturated != std::array<bool, 3>{{false, false, false}}) {
        return fail("equal collective mixer command must be valid and unsaturated");
    }
    for (double command : equal.normalized) {
        if (!near(command, 0.5, 1e-12)) {
            return fail("equal collective must produce equal motor commands");
        }
    }

    const auto positive_roll = aerosim::quad_x_mix_thrust(config, 16.0, {0.2, 0.0, 0.0});
    const auto positive_pitch = aerosim::quad_x_mix_thrust(config, 16.0, {0.0, 0.2, 0.0});
    const auto positive_yaw = aerosim::quad_x_mix_thrust(config, 16.0, {0.0, 0.0, 0.02});
    if (!positive_roll.valid || !positive_pitch.valid || !positive_yaw.valid ||
            !(positive_roll.normalized[2] > positive_roll.normalized[0] &&
                    positive_roll.normalized[3] > positive_roll.normalized[1]) ||
            !(positive_pitch.normalized[1] > positive_pitch.normalized[0] &&
                    positive_pitch.normalized[3] > positive_pitch.normalized[2]) ||
            !(positive_yaw.normalized[0] > positive_yaw.normalized[1] &&
                    positive_yaw.normalized[3] > positive_yaw.normalized[2])) {
        return fail("frozen Quad-X motor-pair signs must preserve FRD roll, pitch, and yaw");
    }

    auto exact_capacity = aerosim::quad_x_mix_thrust(config, 32.0, {0.2, 0.0, 0.0});
    if (!exact_capacity.valid || !exact_capacity.collective_saturated) {
        return fail("exact-capacity collective must preserve differential with an explicit collective saturation");
    }
    if (near(exact_capacity.normalized[0], exact_capacity.normalized[2], 1e-12) ||
            achieved_roll(config, exact_capacity.normalized) <= 0.0) {
        return fail("exact-capacity mixer must preserve requested roll direction");
    }

    const auto oversized_axis = aerosim::quad_x_mix_thrust(config, 16.0, {100.0, 0.0, 0.0});
    if (!oversized_axis.valid || !oversized_axis.axis_saturated[0]) {
        return fail("oversized roll torque must scale the roll axis and remain valid");
    }
    for (double command : oversized_axis.normalized) {
        if (!std::isfinite(command) || command < 0.0 || command > 1.0) {
            return fail("scaled mixer commands must remain finite and within motor limits");
        }
    }

    auto invalid_position = config;
    invalid_position.per_motor.position_frd[0].z = 2e-9;
    if (aerosim::validate_per_motor_config(invalid_position.per_motor)) {
        return fail("non-planar Quad-X geometry must fail loud");
    }

    auto invalid_spin = config;
    invalid_spin.per_motor.spin_direction[1] = 1.0;
    if (aerosim::validate_per_motor_config(invalid_spin.per_motor)) {
        return fail("invalid Quad-X spin order must fail loud");
    }

    const auto invalid_command = aerosim::quad_x_mix_thrust(config, 16.0, {NAN, 0.0, 0.0});
    if (invalid_command.valid) {
        return fail("non-finite mixer input must fail loud");
    }

    return EXIT_SUCCESS;
}
