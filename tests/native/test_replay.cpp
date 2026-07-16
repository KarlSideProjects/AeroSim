#include "aerosim_replay.hpp"

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool same_bits(double a, double b) {
    return std::memcmp(&a, &b, sizeof(double)) == 0;
}

bool same_sample_bits(const aerosim::TrajectorySample &a, const aerosim::TrajectorySample &b) {
    return same_bits(a.time_seconds, b.time_seconds) &&
            same_bits(a.state.position.x, b.state.position.x) &&
            same_bits(a.state.position.y, b.state.position.y) &&
            same_bits(a.state.position.z, b.state.position.z) &&
            same_bits(a.state.orientation.x, b.state.orientation.x) &&
            same_bits(a.state.orientation.y, b.state.orientation.y) &&
            same_bits(a.state.orientation.z, b.state.orientation.z) &&
            same_bits(a.state.orientation.w, b.state.orientation.w) &&
            same_bits(a.state.velocity.x, b.state.velocity.x) &&
            same_bits(a.state.velocity.y, b.state.velocity.y) &&
            same_bits(a.state.velocity.z, b.state.velocity.z) &&
            same_bits(a.state.angular_velocity.x, b.state.angular_velocity.x) &&
            same_bits(a.state.angular_velocity.y, b.state.angular_velocity.y) &&
            same_bits(a.state.angular_velocity.z, b.state.angular_velocity.z) &&
            same_bits(a.state.motor_thrust_newtons[0], b.state.motor_thrust_newtons[0]) &&
            same_bits(a.state.motor_thrust_newtons[1], b.state.motor_thrust_newtons[1]) &&
            same_bits(a.state.motor_thrust_newtons[2], b.state.motor_thrust_newtons[2]) &&
            same_bits(a.state.motor_thrust_newtons[3], b.state.motor_thrust_newtons[3]) &&
            same_bits(a.propwash_disturbance_rad_s2.x, b.propwash_disturbance_rad_s2.x) &&
            same_bits(a.propwash_disturbance_rad_s2.y, b.propwash_disturbance_rad_s2.y) &&
            same_bits(a.propwash_disturbance_rad_s2.z, b.propwash_disturbance_rad_s2.z) &&
            a.substeps == b.substeps;
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
    config.per_motor.max_current_per_motor_a = 0.25;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
}

aerosim::RecordedInputSequence standard_maneuver(std::int32_t frames) {
    aerosim::ReplayRecorder recorder;
    for (std::int32_t frame = 0; frame < frames; ++frame) {
        aerosim::FlightCommand command;
        command.throttle = frame < frames / 4 ? 0.62 : 0.50;
        command.roll_degrees = static_cast<double>((frame % 120) - 60) * 0.25;
        command.pitch_degrees = static_cast<double>((frame % 96) - 48) * 0.20;
        command.yaw_rate_degrees_per_second = static_cast<double>((frame % 80) - 40) * 3.0;
        recorder.record(command);
    }
    return recorder.sequence();
}

bool write_artifact(const char *path, const aerosim::TrajectorySample &sample) {
    if (path == nullptr || path[0] == '\0') {
        return true;
    }
    std::ofstream out(path);
    if (!out) {
        return false;
    }
    out << std::setprecision(17)
        << "{\n"
        << "  \"schema_version\": 1,\n"
        << "  \"time_seconds\": " << sample.time_seconds << ",\n"
        << "  \"substeps\": " << sample.substeps << ",\n"
        << "  \"position_m\": ["
        << sample.state.position.x << ", "
        << sample.state.position.y << ", "
        << sample.state.position.z << "],\n"
        << "  \"orientation_xyzw\": ["
        << sample.state.orientation.x << ", "
        << sample.state.orientation.y << ", "
        << sample.state.orientation.z << ", "
        << sample.state.orientation.w << "],\n"
        << "  \"motor_thrust_newtons\": ["
        << sample.state.motor_thrust_newtons[0] << ", "
        << sample.state.motor_thrust_newtons[1] << ", "
        << sample.state.motor_thrust_newtons[2] << ", "
        << sample.state.motor_thrust_newtons[3] << "]\n"
        << "}\n";
    return true;
}

std::string replace_once(std::string value, const std::string &from, const std::string &to) {
    const std::size_t offset = value.find(from);
    if (offset != std::string::npos) {
        value.replace(offset, from.size(), to);
    }
    return value;
}

bool test_complete_session_schema() {
    aerosim::ReplaySessionRecorder recorder(42, "settings-manifest-v1");
    if (!recorder.add_vehicle("DroneA", "drone-a-hash", "{\"mass_kg\":0.72}") ||
            !recorder.add_vehicle("DroneB", "drone-b-hash", "{\"mass_kg\":0.73}")) {
        return false;
    }

    aerosim::FlightCommand command;
    command.throttle = 0.55;
    if (!recorder.record_async_command(0, "DroneA", "task-a", "moveByVelocity", aerosim::ReplayAsyncLifecycle::Submitted) ||
            !recorder.record_async_command(0, "DroneB", "task-a", "hover", aerosim::ReplayAsyncLifecycle::Submitted) ||
            !recorder.record_async_command(1000, "DroneA", "task-a", "moveByVelocity", aerosim::ReplayAsyncLifecycle::Accepted) ||
            !recorder.record_command(1000, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_command(1000, "DroneB", command, aerosim::ReplayControllerAuthority::Px4External) ||
            !recorder.record_simulation_operation(2000, aerosim::ReplaySimulationOperation::Pause) ||
            !recorder.record_simulation_operation(3000, aerosim::ReplaySimulationOperation::StepFrames, 2) ||
            !recorder.record_async_command(4000, "DroneA", "task-a", "moveByVelocity", aerosim::ReplayAsyncLifecycle::Completed)) {
        return false;
    }

    aerosim::CollisionContact contact;
    contact.touching = true;
    contact.normal = {0.0, 1.0, 0.0};
    contact.impulse = {0.0, 2.0, 0.0};
    if (!recorder.record_collision(5000, "DroneB", contact, aerosim::ReplayControllerAuthority::Jolt) ||
            !recorder.record_scene_object(6000, aerosim::ReplaySceneObjectOperation::Spawn,
                    "crate", "primitive_box", {1.0, 2.0, 3.0}) ||
            !recorder.record_environment(7000, "{\"rain\":0.5,\"wind_preset\":\"light\"}") ||
            !recorder.record_simulation_operation(8000, aerosim::ReplaySimulationOperation::Respawn) ||
            !recorder.finish(9000, "completed")) {
        return false;
    }

    const std::string serialized = recorder.serialize();
    if (serialized.empty() || serialized.find("\"schema_version\":1") == std::string::npos ||
            serialized.find("\"seed\":42") == std::string::npos ||
            serialized.find("\"settings_manifest_hash\":\"settings-manifest-v1\"") == std::string::npos ||
            serialized.find("\"vehicles\"") == std::string::npos ||
            serialized.find("\"events\"") == std::string::npos ||
            serialized.find("\"termination\"") == std::string::npos) {
        return false;
    }

    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(serialized, "settings-manifest-v1");
    if (!loaded.ok || loaded.session.seed != 42 || loaded.session.vehicles.size() != 2 ||
            loaded.session.vehicles[0].name != "DroneA" || loaded.session.vehicles[1].name != "DroneB" ||
            loaded.session.events.size() != recorder.session().events.size() ||
            loaded.session.events[1].vehicle_name != "DroneB" ||
            loaded.session.events[6].simulation_value != 2 ||
            loaded.session.events[8].collision.authority != aerosim::ReplayControllerAuthority::Jolt ||
            loaded.session.events[9].object_name != "crate" ||
            loaded.session.events[10].environment_json.find("rain") == std::string::npos ||
            loaded.session.termination_reason != "completed") {
        return false;
    }

    const aerosim::ReplayLoadResult mismatched_manifest = aerosim::load_replay_session(serialized, "other-manifest");
    if (mismatched_manifest.ok || mismatched_manifest.diagnostic.code != aerosim::ReplayDiagnosticCode::IncompatibleManifest) {
        return false;
    }
    const aerosim::ReplayLoadResult unsupported = aerosim::load_replay_session(
            replace_once(serialized, "\"schema_version\":1", "\"schema_version\":99"));
    if (unsupported.ok || unsupported.diagnostic.code != aerosim::ReplayDiagnosticCode::UnsupportedSchema) {
        return false;
    }
    const aerosim::ReplayLoadResult truncated = aerosim::load_replay_session(serialized.substr(0, serialized.size() - 2));
    if (truncated.ok || truncated.diagnostic.code != aerosim::ReplayDiagnosticCode::Truncated) {
        return false;
    }
    const aerosim::ReplayLoadResult corrupt = aerosim::load_replay_session(
            replace_once(serialized, "\"seed\":42", "\"seed\":NaN"));
    if (corrupt.ok || corrupt.diagnostic.code != aerosim::ReplayDiagnosticCode::Corrupt) {
        return false;
    }
    const aerosim::ReplayLoadResult invalid_lifecycle = aerosim::load_replay_session(
            replace_once(serialized, "\"lifecycle\":\"submitted\"", "\"lifecycle\":\"completed\""));
    if (invalid_lifecycle.ok || invalid_lifecycle.diagnostic.code != aerosim::ReplayDiagnosticCode::InvalidLifecycle) {
        return false;
    }
    const aerosim::ReplayLoadResult non_monotonic = aerosim::load_replay_session(
            replace_once(serialized, "\"timestamp_us\":4000", "\"timestamp_us\":100"));
    if (non_monotonic.ok || non_monotonic.diagnostic.code != aerosim::ReplayDiagnosticCode::InvalidSession) {
        return false;
    }
    return true;
}

bool test_session_identity_and_async_validation() {
    aerosim::ReplaySessionRecorder recorder(1, "manifest");
    if (recorder.add_vehicle("Drone A", "hash", "{}") ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::InvalidIdentity ||
            recorder.add_vehicle("DroneA", "", "{}") ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::MissingVehicleConfig ||
            !recorder.add_vehicle("DroneA", "hash-a", "{}") ||
            recorder.add_vehicle("DroneA", "hash-a", "{}") ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::InvalidIdentity ||
            !recorder.add_vehicle("DroneB", "hash-b", "{}")) {
        return false;
    }
    if (recorder.record_command(0, "Unknown", {}, aerosim::ReplayControllerAuthority::FlightCore) ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::UnknownVehicle ||
            !recorder.record_async_command(0, "DroneA", "task", "hover", aerosim::ReplayAsyncLifecycle::Submitted) ||
            recorder.record_async_command(1, "DroneA", "task", "hover", aerosim::ReplayAsyncLifecycle::Completed) ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::InvalidLifecycle ||
            !recorder.record_async_command(1, "DroneA", "task", "hover", aerosim::ReplayAsyncLifecycle::Accepted) ||
            !recorder.record_async_command(2, "DroneA", "task", "hover", aerosim::ReplayAsyncLifecycle::Cancelled) ||
            recorder.record_async_command(3, "DroneA", "task", "hover", aerosim::ReplayAsyncLifecycle::Completed) ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::InvalidLifecycle) {
        return false;
    }
    return true;
}

bool test_first_divergence_report() {
    aerosim::ReplaySessionRecorder recorder(7, "manifest");
    recorder.add_vehicle("DroneA", "hash-a", "{}");
    recorder.add_vehicle("DroneB", "hash-b", "{}");
    aerosim::FlightCommand command;
    recorder.record_command(1000, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore);
    recorder.finish(2000, "completed");
    const aerosim::ReplaySession expected = recorder.session();
    aerosim::ReplaySession actual = expected;
    actual.events[0].command.throttle = 0.25;
    const aerosim::ReplayDivergence divergence = aerosim::compare_replay_sessions(expected, actual);
    return divergence.diverged && divergence.timestamp_us == 1000 &&
            divergence.vehicle_name == "DroneA" && divergence.field == "command.throttle" &&
            divergence.expected == "0" && divergence.actual == "0.25" && divergence.tolerance == 0.0;
}

} // namespace

int main() {
    aerosim::ReplayRecorder named_recorder("DroneA");
    aerosim::FlightCommand named_command;
    named_recorder.record(named_command);
    if (named_recorder.vehicle_name() != "DroneA" || named_recorder.sequence().vehicle_name != "DroneA") {
        return fail("replay recordings must retain their named vehicle identity");
    }
    aerosim::ReplayRecorder other_named_recorder("DroneB");
    other_named_recorder.record(named_command);
    if (named_recorder.serialized_identity() == other_named_recorder.serialized_identity() ||
            named_recorder.serialized_identity().find("DroneA") == std::string::npos ||
            other_named_recorder.serialized_identity().find("DroneB") == std::string::npos) {
        return fail("serialized replay identity must keep two vehicle records distinct");
    }
    const std::string special_name = "Drone\"\\\x01\n";
    aerosim::ReplayRecorder special_recorder(special_name);
    special_recorder.record(named_command);
    const std::string expected_special_identity =
            "{\"vehicle_name\":\"Drone" +
            std::string("\\\"") +
            "\\\\" +
            "\\u0001" +
            "\\n\",\"frame_count\":1}";
    if (special_recorder.serialized_identity() != expected_special_identity) {
        return fail("serialized replay identity must escape JSON special characters");
    }

    aerosim::SimulationConfig config;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

    aerosim::ReplayRecorder recorder;
    for (int frame = 0; frame < config.physics_hz * 2; ++frame) {
        aerosim::FlightCommand command;
        command.throttle = 0.52 + static_cast<double>(frame % 7) * 0.01;
        command.roll_degrees = static_cast<double>((frame % 21) - 10);
        command.pitch_degrees = static_cast<double>((frame % 17) - 8);
        command.yaw_rate_degrees_per_second = static_cast<double>((frame % 11) - 5) * 15.0;
        recorder.record(command);
    }

    const aerosim::RecordedInputSequence inputs = recorder.sequence();
    const auto first = aerosim::replay_angle_mode(config, inputs);
    const auto second = aerosim::replay_angle_mode(config, inputs);

    if (first.size() != inputs.frames.size() || second.size() != inputs.frames.size()) {
        return fail("replay must emit one trajectory sample for every recorded input frame");
    }
    for (std::size_t i = 0; i < inputs.frames.size(); ++i) {
        if (!same_sample_bits(first[i], second[i])) {
            return fail("same-platform replay must be bitwise identical for the same input sequence");
        }
    }

    aerosim::SimulationConfig standard_config;
    standard_config.seconds = 60.0;
    standard_config.physics_hz = 240;
    standard_config.substep_hz = 1000;
    configure_power_model(standard_config);

    const auto standard_inputs = standard_maneuver(
            static_cast<std::int32_t>(standard_config.seconds * standard_config.physics_hz));
    const auto reference = aerosim::replay_angle_mode(standard_config, standard_inputs);
    const auto platform_run = aerosim::replay_angle_mode(standard_config, standard_inputs);
    const aerosim::ReplayDelta delta = aerosim::compare_replay_final_state(
            reference.back(),
            platform_run.back());
    if (!aerosim::within_g06a_tolerance(delta)) {
        return fail("G0.6a cross-platform final-state tolerance check rejected the standard maneuver");
    }
    if (!write_artifact(std::getenv("AEROSIM_REPLAY_ARTIFACT"), platform_run.back())) {
        return fail("failed to write replay terminal-state artifact");
    }

    if (!test_complete_session_schema()) {
        return fail("complete-session replay schema must round-trip and diagnose load failures");
    }
    if (!test_session_identity_and_async_validation()) {
        return fail("complete-session replay must validate identities and async lifecycle transitions");
    }
    if (!test_first_divergence_report()) {
        return fail("complete-session replay must report the first field divergence");
    }

    return EXIT_SUCCESS;
}
