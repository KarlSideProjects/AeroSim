#include "aerosim_flight_control.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

constexpr double kPi = 3.14159265358979323846;

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

void configure_power_model(aerosim::SimulationConfig &config) {
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = config.mass_kg * config.gravity_mps2 * 2.0;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.battery_cell_resistance_ohm = 0.003;
    config.battery_remaining_mah = 1040.0;
    config.max_total_current_a = 108.0;
    config.max_motor_rpm = 15000.0;
    config.config_hash = "canonical-config-hash";
    config.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    config.per_motor.max_thrust_per_motor_newtons = config.max_total_thrust_newtons / 4.0;
    config.per_motor.max_current_per_motor_a = config.max_total_current_a / 4.0;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
}

} // namespace

int main() {
    aerosim::SimulationConfig config;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

    aerosim::RigidBodyState state;
    aerosim::SimulationClock clock;
    aerosim::FlightController controller;
    if (!controller.arm(0.0)) {
        return fail("telemetry setup must arm from low throttle");
    }

    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    aerosim::TrajectorySample sample;
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        sample = controller.step_angle_mode(state, clock, config, hover);
    }

    const aerosim::TelemetrySnapshot &snapshot = controller.telemetry_snapshot();
    if (snapshot.schema_version != aerosim::kTelemetrySnapshotSchemaVersion ||
            snapshot.timestamp_us == 0 ||
            snapshot.publish_count < 30 ||
            snapshot.publish_count > 31 ||
            snapshot.snapshot_hz != aerosim::kTelemetrySnapshotHz) {
        return fail("TelemetrySnapshot schema/version/update rate must be frozen at 30 Hz");
    }
    const auto sample_timestamp_us = static_cast<std::uint64_t>(std::llround(sample.time_seconds * 1000000.0));
    if (sample_timestamp_us < snapshot.timestamp_us || sample_timestamp_us - snapshot.timestamp_us > 100000) {
        return fail("TelemetrySnapshot latency must stay <= 100 ms");
    }
    if (!snapshot.armed || snapshot.mode != "ANGLE") {
        return fail("TelemetrySnapshot must expose armed state and flight mode from flight control truth");
    }
    if (snapshot.config_hash != config.config_hash) {
        return fail("TelemetrySnapshot must carry the canonical config hash before publication");
    }

    double motor_sum = 0.0;
    const double max_motor_speed_rad_s = config.max_motor_rpm * 2.0 * kPi / 60.0;
    for (const aerosim::MotorTelemetry &motor : snapshot.motors) {
        motor_sum += motor.thrust_newtons;
        const double expected_current = config.per_motor.max_thrust_per_motor_newtons > 0.0
                ? config.per_motor.max_current_per_motor_a *
                        std::clamp(motor.thrust_newtons / config.per_motor.max_thrust_per_motor_newtons, 0.0, 1.0)
                : 0.0;
        const double expected_speed = aerosim::motor_speed_rad_s_from_thrust(
                motor.thrust_newtons,
                config.per_motor.max_thrust_per_motor_newtons,
                config.max_motor_rpm);
        if (motor.thrust_newtons <= 0.0 || motor.speed_rad_s <= 0.0 || motor.speed_rad_s > max_motor_speed_rad_s ||
                !near(motor.speed_rad_s, expected_speed, 1e-9) ||
                !near(motor.current_a, expected_current, 1e-9) ||
                motor.saturated) {
            return fail("TelemetrySnapshot motor thrust/rad_s/current/saturation must match controller truth");
        }
    }
    if (!near(motor_sum, controller.motor_thrust_newtons(), 1e-9)) {
        return fail("TelemetrySnapshot per-motor thrust must sum to the native motor thrust truth");
    }

    const double expected_sag = config.max_total_current_a * hover.throttle *
            config.battery_cell_resistance_ohm * config.battery_cells;
    if (!near(snapshot.battery.sag_v, expected_sag, 1e-9) ||
            !near(snapshot.battery.voltage_v, config.battery_nominal_voltage_v - expected_sag, 1e-9) ||
            !near(snapshot.battery.remaining_mah, config.battery_remaining_mah, 1e-9)) {
        return fail("TelemetrySnapshot battery voltage sag must come from the native power model");
    }
    if (snapshot.wind_world_mps.x != 0.0 || snapshot.wind_world_mps.y != 0.0 || snapshot.wind_world_mps.z != 0.0 ||
            snapshot.wind_body_mps.x != 0.0 || snapshot.wind_body_mps.y != 0.0 || snapshot.wind_body_mps.z != 0.0 ||
            snapshot.turbulence_intensity != 0.0 ||
            snapshot.ground_effect_gain != 0.0 ||
            snapshot.downwash_force_n != 0.0 ||
            snapshot.propwash_disturbance_rad_s2.x != 0.0 ||
            snapshot.propwash_disturbance_rad_s2.y != 0.0 ||
            snapshot.propwash_disturbance_rad_s2.z != 0.0 ||
            snapshot.drag_body_n.x != 0.0 ||
            snapshot.drag_body_n.y != 0.0 ||
            snapshot.drag_body_n.z != 0.0) {
        return fail("TelemetrySnapshot disabled effects must publish zero indicators");
    }

    aerosim::SimulationConfig windy_config = config;
    windy_config.wind_world_mps = {1.0, 2.0, 3.0};
    windy_config.wind_turbulence_mps = {0.1, 0.2, 0.3};
    aerosim::RigidBodyState windy_state;
    aerosim::SimulationClock windy_clock;
    aerosim::FlightController windy_controller;
    if (!windy_controller.arm(0.0)) {
        return fail("wind telemetry setup must arm from low throttle");
    }
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        windy_controller.step_angle_mode(windy_state, windy_clock, windy_config, hover);
    }
    const aerosim::TelemetrySnapshot &windy_snapshot = windy_controller.telemetry_snapshot();
    if (!near(windy_snapshot.wind_world_mps.x, 1.0, 1e-12) ||
            !near(windy_snapshot.wind_world_mps.y, 3.0, 1e-12) ||
            !near(windy_snapshot.wind_world_mps.z, -2.0, 1e-12) ||
            !near(windy_snapshot.wind_body_mps.x, 1.0, 1e-12) ||
            !near(windy_snapshot.wind_body_mps.y, 3.0, 1e-12) ||
            !near(windy_snapshot.wind_body_mps.z, -2.0, 1e-12) ||
            !near(windy_snapshot.turbulence_intensity, std::sqrt(0.14), 1e-12)) {
        return fail("TelemetrySnapshot must publish configured wind in world/body frames and intensity");
    }

    windy_config.body_drag.enabled = true;
    windy_config.body_drag.drag_coefficient = {1.0, 1.0, 1.0};
    windy_config.body_drag.frontal_area_m2 = {0.1, 0.2, 0.3};
    windy_config.body_drag.center_of_pressure_frd_m = {0.1, 0.0, 0.0};
    windy_config.air_density_kg_m3 = 1.2;
    aerosim::RigidBodyState body_drag_state;
    aerosim::SimulationClock body_drag_clock;
    aerosim::FlightController body_drag_controller;
    if (!body_drag_controller.arm(0.0)) {
        return fail("body drag telemetry setup must arm from low throttle");
    }
    for (int frame = 0; frame < config.physics_hz; ++frame) {
        body_drag_controller.step_angle_mode(body_drag_state, body_drag_clock, windy_config, hover);
    }
    const aerosim::TelemetrySnapshot &body_drag_snapshot = body_drag_controller.telemetry_snapshot();
    if (body_drag_snapshot.body_drag_operating_state != "active" ||
            body_drag_snapshot.body_drag_evidence_state != "provisional" ||
            !near(body_drag_snapshot.air_density_kg_m3, 1.2, 1e-12) ||
            body_drag_snapshot.body_drag_force_body_frd_n_mean.x == 0.0 ||
            body_drag_snapshot.body_drag_reason_code != "active_provisional") {
        return fail("TelemetrySnapshot must expose native body-drag values and explicit provisional state");
    }

    aerosim::FlightController unavailable_controller;
    aerosim::TrajectorySample unavailable_sample;
    unavailable_sample.time_seconds = 1.0;
    unavailable_sample.body_drag_force_body_frd_n_mean = {9.0, 8.0, 7.0};
    unavailable_sample.body_drag_torque_body_frd_nm_mean = {6.0, 5.0, 4.0};
    unavailable_sample.body_drag_force_applied = true;
    unavailable_sample.body_drag_torque_applied = true;
    unavailable_sample.state.motor_thrust_newtons = {{0.5, 0.6, 0.7, 0.8}};
    aerosim::SimulationConfig unavailable_config = windy_config;
    unavailable_config.config_hash = "canonical-config-hash";
    unavailable_controller.publish_applied_telemetry(unavailable_sample, unavailable_config, 0.5, "PX4_ACTUATOR");
    const aerosim::TelemetrySnapshot &px4_snapshot = unavailable_controller.telemetry_snapshot();
    if (px4_snapshot.body_drag_operating_state != "active" ||
            px4_snapshot.control_authority != "px4_external" || px4_snapshot.armed_available ||
            px4_snapshot.pid_available || px4_snapshot.armed ||
            !near(px4_snapshot.motors[0].thrust_newtons, 0.5, 1e-12) ||
            !near(px4_snapshot.motors[1].thrust_newtons, 0.6, 1e-12)) {
        return fail("external PX4 authority must publish its applied motor and body-drag truth");
    }
    for (int frame = 1; frame <= 24; ++frame) {
        unavailable_sample.time_seconds = 1.0 + static_cast<double>(frame) / 240.0;
        unavailable_controller.publish_unavailable_telemetry(unavailable_sample, unavailable_config, "JOLT");
    }
    const aerosim::TelemetrySnapshot &unavailable_snapshot = unavailable_controller.telemetry_snapshot();
    if (unavailable_snapshot.publish_count != 4 ||
            unavailable_snapshot.body_drag_operating_state != "unavailable" ||
            unavailable_snapshot.body_drag_evidence_state != "unavailable" ||
            unavailable_snapshot.body_drag_reason_code != "authority_unavailable" ||
            std::isfinite(unavailable_snapshot.body_drag_force_body_frd_n_mean.x) ||
            std::isfinite(unavailable_snapshot.body_drag_torque_body_frd_nm_mean.x)) {
        return fail("unavailable telemetry must retain the frozen 30 Hz cadence without fabricated body-drag values");
    }

    aerosim::SimulationConfig invalid_config = windy_config;
    invalid_config.air_density_kg_m3 = 0.0;
    aerosim::RigidBodyState invalid_state;
    aerosim::SimulationClock invalid_clock;
    aerosim::FlightController invalid_controller;
    if (!invalid_controller.arm(0.0)) {
        return fail("out-of-domain telemetry setup must arm from low throttle");
    }
    invalid_controller.step_angle_mode(invalid_state, invalid_clock, invalid_config, hover);
    const aerosim::TelemetrySnapshot &invalid_snapshot = invalid_controller.telemetry_snapshot();
    if (invalid_snapshot.body_drag_operating_state != "out_of_domain" ||
            invalid_snapshot.body_drag_evidence_state != "unavailable" ||
            invalid_snapshot.body_drag_reason_code != "invalid_configuration" ||
            std::isfinite(invalid_snapshot.body_drag_force_body_frd_n_mean.x) ||
            std::isfinite(invalid_snapshot.body_drag_torque_body_frd_nm_mean.x)) {
        return fail("TelemetrySnapshot must use out_of_domain and unavailable values for invalid body drag");
    }

    aerosim::FlightCommand saturated;
    saturated.throttle = 1.0;
    saturated.pitch_degrees = 90.0;
    for (int frame = 0; frame < 20; ++frame) {
        controller.step_angle_mode(state, clock, config, saturated);
    }
    const aerosim::TelemetrySnapshot &saturated_snapshot = controller.telemetry_snapshot();
    if (!saturated_snapshot.motors[0].saturated || !saturated_snapshot.pid[0].saturated) {
        return fail("TelemetrySnapshot must expose motor and PID saturation from native flight control");
    }

    return EXIT_SUCCESS;
}
