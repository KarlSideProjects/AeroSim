// Pins the sign convention that connects a stick deflection to motor thrust.
//
// The mixer derives its roll and pitch columns from the motor geometry rather
// than from constants, so the direction a command actually flies is not visible
// by reading the mapping table alone. These assertions state it in terms of the
// physical outcome: which side of the airframe carries more thrust.
#include "aerosim_flight_control.hpp"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

// Motor order matches config/drones/5_inch_6s.json:
// 0 rear_right, 1 front_right, 2 rear_left, 3 front_left, in FRD metres.
constexpr std::size_t kRearRight = 0;
constexpr std::size_t kFrontRight = 1;
constexpr std::size_t kRearLeft = 2;
constexpr std::size_t kFrontLeft = 3;

double shipped_hover_throttle() {
    return 0.42;
}

aerosim::SimulationConfig shipped_5_inch_6s_config() {
    aerosim::HardwareConfig hardware;
    hardware.set_mass_kg(0.72);
    hardware.set_power_model(64.8, shipped_hover_throttle(), 0.030, 22.2, 6.0, 0.003, 108.0);
    hardware.set_altitude_hold_noise_deadband_m(0.10);
    aerosim::PerMotorPhysicsConfig per_motor;
    per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    per_motor.max_thrust_per_motor_newtons = 16.2;
    per_motor.max_current_per_motor_a = 27.0;
    per_motor.yaw_torque_per_newton = 0.1575 / 16.2;
    per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    hardware.set_per_motor_model(per_motor);
    aerosim::SimulationConfig config = hardware.simulation_config();
    config.physics_hz = 240;
    config.substep_hz = 1000;
    return config;
}

// Runs one angle-mode step from a level hover and returns the motor thrusts.
std::array<double, 4> thrusts_for(double roll_degrees, double pitch_degrees) {
    aerosim::SimulationConfig config = shipped_5_inch_6s_config();
    aerosim::FlightController controller;
    aerosim::RigidBodyState state;
    aerosim::SimulationClock clock;
    controller.arm(0.0);
    aerosim::FlightCommand command;
    command.throttle = shipped_hover_throttle();
    command.roll_degrees = roll_degrees;
    command.pitch_degrees = pitch_degrees;
    controller.step_angle_mode(state, clock, config, command, state.orientation);
    return state.motor_thrust_newtons;
}

double left_thrust(const std::array<double, 4> &t) {
    return t[kRearLeft] + t[kFrontLeft];
}

double right_thrust(const std::array<double, 4> &t) {
    return t[kRearRight] + t[kFrontRight];
}

double front_thrust(const std::array<double, 4> &t) {
    return t[kFrontLeft] + t[kFrontRight];
}

double rear_thrust(const std::array<double, 4> &t) {
    return t[kRearLeft] + t[kRearRight];
}

}  // namespace

int main() {
    // A right bank is produced by lifting the left side of the airframe, so a
    // positive roll command must put more thrust into the two left motors.
    // Mode 2 puts roll on the right stick's horizontal axis, where Godot
    // reports a right deflection as positive, so this is what "stick right
    // rolls right" reduces to.
    const std::array<double, 4> roll_right = thrusts_for(10.0, 0.0);
    if (!(left_thrust(roll_right) > right_thrust(roll_right))) {
        return fail("a positive roll command must lift the left side and bank right");
    }

    const std::array<double, 4> roll_left = thrusts_for(-10.0, 0.0);
    if (!(right_thrust(roll_left) > left_thrust(roll_left))) {
        return fail("a negative roll command must lift the right side and bank left");
    }

    // A nose-up attitude is produced by lifting the front of the airframe, so a
    // positive pitch command must put more thrust into the two front motors.
    // Godot reports an upward deflection of the right stick's vertical axis as
    // negative, which is what makes stick-forward command nose-down.
    const std::array<double, 4> pitch_up = thrusts_for(0.0, 10.0);
    if (!(front_thrust(pitch_up) > rear_thrust(pitch_up))) {
        return fail("a positive pitch command must lift the nose");
    }

    const std::array<double, 4> pitch_down = thrusts_for(0.0, -10.0);
    if (!(rear_thrust(pitch_down) > front_thrust(pitch_down))) {
        return fail("a negative pitch command must drop the nose");
    }

    // Roll must not leak into pitch, or an axis swap in the input profile would
    // still satisfy the assertions above.
    if (std::abs(front_thrust(roll_right) - rear_thrust(roll_right)) >
            std::abs(left_thrust(roll_right) - right_thrust(roll_right)) * 0.05) {
        return fail("a roll command must not produce a pitching moment");
    }
    if (std::abs(left_thrust(pitch_up) - right_thrust(pitch_up)) >
            std::abs(front_thrust(pitch_up) - rear_thrust(pitch_up)) * 0.05) {
        return fail("a pitch command must not produce a rolling moment");
    }

    std::cout << "stick axis convention ok\n";
    return EXIT_SUCCESS;
}
