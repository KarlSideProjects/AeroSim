#include "aerosim_simulation.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

aerosim::SimulationConfig config() {
    aerosim::SimulationConfig value;
    value.mass_kg = 0.72;
    value.gravity_mps2 = 9.80665;
    value.hover_throttle = 0.42;
    value.max_total_thrust_newtons = 64.8;
    value.battery_nominal_voltage_v = 22.2;
    value.battery_cells = 6.0;
    value.battery_cell_resistance_ohm = 0.003;
    value.max_total_current_a = 108.0;
    value.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    value.per_motor.max_thrust_per_motor_newtons = 16.2;
    value.per_motor.max_current_per_motor_a = 27.0;
    value.per_motor.yaw_torque_per_newton = 0.01;
    value.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    value.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    return value;
}

bool same_state(const aerosim::RigidBodyState &left, const aerosim::RigidBodyState &right) {
    return left.position.x == right.position.x && left.position.y == right.position.y && left.position.z == right.position.z &&
            left.velocity.x == right.velocity.x && left.velocity.y == right.velocity.y && left.velocity.z == right.velocity.z &&
            left.orientation.x == right.orientation.x && left.orientation.y == right.orientation.y &&
            left.orientation.z == right.orientation.z && left.orientation.w == right.orientation.w &&
            left.angular_velocity.x == right.angular_velocity.x && left.angular_velocity.y == right.angular_velocity.y &&
            left.angular_velocity.z == right.angular_velocity.z &&
            left.motor_thrust_newtons == right.motor_thrust_newtons && left.motor_rpm == right.motor_rpm;
}

} // namespace

int main() {
    const aerosim::SimulationConfig nominal = config();
    const aerosim::RigidBodyState initial_state;
    const aerosim::MotorCommands low_commands{{0.05, 0.05, 0.05, 0.05}};
    const aerosim::Px4SupportLiftReadiness low = aerosim::px4_support_lift_readiness(nominal, initial_state, low_commands);
    if (!low.valid || low.ready || !(low.projected_lift_newtons < low.required_lift_newtons)) {
        return fail("low PX4 collective must not release supported launch");
    }
    if (!same_state(initial_state, aerosim::RigidBodyState{})) {
        return fail("PX4 support lift readiness must not mutate the simulation state");
    }

    const aerosim::MotorCommands takeoff_commands{{0.50, 0.50, 0.50, 0.50}};
    const aerosim::Px4SupportLiftReadiness sagged = aerosim::px4_support_lift_readiness(nominal, initial_state, takeoff_commands);
    aerosim::SimulationConfig without_sag = nominal;
    without_sag.battery_cell_resistance_ohm = 0.0;
    const aerosim::Px4SupportLiftReadiness unsagged = aerosim::px4_support_lift_readiness(without_sag, initial_state, takeoff_commands);
    if (!sagged.valid || !sagged.ready || !unsagged.ready ||
            !(sagged.projected_lift_newtons < unsagged.projected_lift_newtons)) {
        return fail("lift readiness must use the configured battery sag model");
    }

    aerosim::SimulationConfig heavy = nominal;
    heavy.mass_kg = 4.0;
    const aerosim::Px4SupportLiftReadiness heavy_aircraft = aerosim::px4_support_lift_readiness(heavy, initial_state, takeoff_commands);
    if (!heavy_aircraft.valid || heavy_aircraft.ready ||
            !(heavy_aircraft.required_lift_newtons > sagged.required_lift_newtons)) {
        return fail("lift readiness must use the configured aircraft mass and gravity");
    }

    aerosim::RigidBodyState sideways_state;
    constexpr double kRootHalf = 0.7071067811865476;
    sideways_state.orientation = {kRootHalf, 0.0, 0.0, kRootHalf};
    const aerosim::Px4SupportLiftReadiness sideways = aerosim::px4_support_lift_readiness(nominal, sideways_state, takeoff_commands);
    if (!sideways.valid || sideways.ready ||
            !(std::abs(sideways.projected_lift_newtons) < 1.0e-9)) {
        return fail("lift readiness must project configured motor thrust through the current attitude");
    }
    aerosim::RigidBodyState expected_sideways_state;
    expected_sideways_state.orientation = {kRootHalf, 0.0, 0.0, kRootHalf};
    if (!same_state(sideways_state, expected_sideways_state)) {
        return fail("lift readiness must not normalize or otherwise mutate the sampled attitude");
    }

    // The PX4 Iris profile derives these values from its checked-in prop table:
    // 1.5 kg, 10,504.23 max RPM, and 7.0664 N maximum thrust per rotor.
    aerosim::SimulationConfig iris = nominal;
    iris.mass_kg = 1.5;
    iris.battery_cell_resistance_ohm = 0.0;
    iris.max_motor_rpm = 10504.23;
    iris.per_motor.max_thrust_per_motor_newtons = 7.0664;
    iris.px4_actuator_rpm_mapping = true;
    const aerosim::MotorCommands iris_hover{{0.721400079425549, 0.721400079425549,
            0.721400079425549, 0.721400079425549}};
    const aerosim::MotorCommands iris_linear_hover{{0.5204196974414129, 0.5204196974414129,
            0.5204196974414129, 0.5204196974414129}};
    const aerosim::Px4SupportLiftReadiness iris_hover_readiness =
            aerosim::px4_support_lift_readiness(iris, initial_state, iris_hover);
    const aerosim::Px4SupportLiftReadiness iris_early_readiness =
            aerosim::px4_support_lift_readiness(iris, initial_state, iris_linear_hover);
    if (!iris_hover_readiness.valid || !iris_hover_readiness.ready ||
            std::abs(iris_hover_readiness.command_thrust_newtons - iris_hover_readiness.required_lift_newtons) > 1.0e-3 ||
            !iris_early_readiness.valid || iris_early_readiness.ready ||
            !(iris_early_readiness.command_thrust_newtons < iris_early_readiness.required_lift_newtons)) {
        return fail("PX4 Iris RPM-mapped hover and support-release thresholds must follow the derived prop table");
    }

    return EXIT_SUCCESS;
}
