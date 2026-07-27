#include "aerosim_replay.hpp"
#include "aerosim_wind.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
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

std::string double_bits(double value) {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    std::ostringstream out;
    out << std::hex << std::setw(16) << std::setfill('0') << bits;
    return out.str();
}

bool write_artifact(const char *path, const aerosim::ReplaySession &session) {
    if (path == nullptr || path[0] == '\0') {
        return true;
    }
    std::ofstream out(path);
    if (!out) {
        return false;
    }
    if (session.checkpoints.empty()) {
        return false;
    }
    const aerosim::ReplayRunCheckpoint &checkpoint = session.checkpoints.front();
    std::ostringstream manifest;
    bool first = true;
    const auto add = [&](const std::string &name, double value) {
        if (!first) {
            manifest << ',';
        }
        first = false;
        manifest << '"' << name << "\":\"" << double_bits(value) << '"';
    };
    const auto add_vec = [&](const std::string &prefix, const aerosim::Vec3 &value) {
        add(prefix + ".x", value.x); add(prefix + ".y", value.y); add(prefix + ".z", value.z);
    };
    const auto add_state = [&](const std::string &prefix, const aerosim::RigidBodyState &state) {
        add_vec(prefix + ".position", state.position);
        add(prefix + ".orientation.x", state.orientation.x); add(prefix + ".orientation.y", state.orientation.y);
        add(prefix + ".orientation.z", state.orientation.z); add(prefix + ".orientation.w", state.orientation.w);
        add_vec(prefix + ".velocity", state.velocity); add_vec(prefix + ".angular_velocity", state.angular_velocity);
        add_vec(prefix + ".propwash", state.propwash_disturbance_rad_s2);
        for (std::size_t motor = 0; motor < state.motor_thrust_newtons.size(); ++motor) {
            add(prefix + ".motor[" + std::to_string(motor) + "]", state.motor_thrust_newtons[motor]);
        }
    };
    const auto add_sample = [&](const std::string &prefix, const aerosim::TrajectorySample &sample) {
        add(prefix + ".time_seconds", sample.time_seconds); add_state(prefix + ".state", sample.state);
        add_vec(prefix + ".propwash", sample.propwash_disturbance_rad_s2);
        add_vec(prefix + ".airspeed", sample.airspeed_body_frd_mps_mean);
        add_vec(prefix + ".body_drag_force", sample.body_drag_force_body_frd_n_mean);
        add_vec(prefix + ".body_drag_torque", sample.body_drag_torque_body_frd_nm_mean);
        add_vec(prefix + ".a3_drag_force", sample.a3_drag_force_body_frd_n_mean);
        add(prefix + ".air_density", sample.air_density_kg_m3);
    };
    for (std::size_t vehicle = 0; vehicle < 2; ++vehicle) {
        const std::string prefix = "vehicle[" + std::to_string(vehicle) + "]";
        add_state(prefix + ".state", vehicle == 0 ? checkpoint.state.upper : checkpoint.state.lower);
        const aerosim::FlightControlState &controller = checkpoint.controllers[vehicle];
        add_vec(prefix + ".controller.target_angle", controller.target_angle_frd);
        add_vec(prefix + ".controller.target_rate", controller.target_rate_frd);
        for (std::size_t axis = 0; axis < 3; ++axis) add(prefix + ".controller.integral[" + std::to_string(axis) + "]", controller.rate_integral[axis]);
        add_vec(prefix + ".controller.previous_error", controller.previous_rate_error_frd);
        add_vec(prefix + ".controller.derivative", controller.filtered_rate_derivative_frd);
        add(prefix + ".controller.motor_total", controller.motor_thrust_newtons);
        add(prefix + ".clock.substep_accumulator", checkpoint.clocks[vehicle].substep_accumulator);
        add_sample(prefix + ".first_response", checkpoint.first_response_substeps[vehicle]);
    }
    std::string serialized = aerosim::serialize_replay_session(session);
    if (serialized.empty() || serialized.back() != '}') {
        return false;
    }
    serialized.pop_back();
    serialized += ",\"ieee754_bits\":{" + manifest.str() + "}}";
    out << serialized;
    return true;
}

std::string replace_once(std::string value, const std::string &from, const std::string &to) {
    const std::size_t offset = value.find(from);
    if (offset != std::string::npos) {
        value.replace(offset, from.size(), to);
    }
    return value;
}

aerosim::SimulationConfig replay_test_config() {
    aerosim::SimulationConfig config;
    config.physics_hz = 100;
    config.substep_hz = 100;
    config.gravity_mps2 = 9.80665;
    config.mass_kg = 1.0;
    configure_power_model(config);
    config.per_motor.inertia_kg_m2 = {0.01, 0.01, 0.02};
    config.per_motor.max_thrust_per_motor_newtons = 1.0;
    config.per_motor.max_current_per_motor_a = 1.0;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.10, 0.10, 0.0},
            {0.10, 0.10, 0.0},
            {-0.10, -0.10, 0.0},
            {0.10, -0.10, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
    return config;
}

std::string complete_atmosphere(std::uint32_t seed = 1) {
    return "{\"atmosphere\":{\"preset\":\"calm\",\"steady_wind\":[0,0,0],"
            "\"turbulence_sigma\":[0,0,0],\"reference_airspeed_mps\":30,\"scale_length_m\":200,"
            "\"shear_reference_height_m\":1,\"shear_exponent\":1,\"shear_enabled\":false,\"seed\":" +
            std::to_string(seed) + "},\"atmosphere_air_density_kg_m3\":1.225}";
}

bool test_replay_reconstructs_seeded_atmosphere() {
    const std::string atmosphere_a =
            "{\"wind_preset\":\"light\",\"steady_wind\":[0,0,0],\"atmosphere\":{"
            "\"preset\":\"light\",\"steady_wind\":[0,0,0],\"turbulence_sigma\":[0.5,0.5,0.5],"
            "\"reference_airspeed_mps\":30,\"scale_length_m\":200,\"shear_reference_height_m\":1,"
            "\"shear_exponent\":1,\"shear_enabled\":true,\"seed\":11},"
            "\"atmosphere_air_density_kg_m3\":1.225}";
    const std::string atmosphere_b = replace_once(atmosphere_a, "\"seed\":11", "\"seed\":12");
    auto make_session = [](const std::string &environment) {
        aerosim::ReplaySessionRecorder recorder(42, "settings-manifest-v1");
        recorder.add_vehicle("DroneA", "drone-a-hash", "{\"mass_kg\":1.0}");
        recorder.add_vehicle("DroneB", "drone-b-hash", "{\"mass_kg\":1.0}");
        recorder.record_environment(0, environment);
        aerosim::FlightCommand command;
        command.throttle = 0.5;
        recorder.record_command(1000, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore);
        recorder.record_command(1000, "DroneB", command, aerosim::ReplayControllerAuthority::FlightCore);
        recorder.finish(20000, "completed");
        return recorder.session();
    };
    aerosim::SimulationConfig config = replay_test_config();
    config.body_drag.enabled = true;
    config.body_drag.drag_coefficient = {1.0, 1.0, 1.0};
    config.body_drag.frontal_area_m2 = {1.0, 1.0, 1.0};
    config.air_density_kg_m3 = 1.225;
    config.initial_state.position.y = 2.0;
    config.initial_state.velocity = {5.0, 0.0, 0.0};
    aerosim::DualAircraftConfig configs{config, config};
    const std::array<std::string, 2> hashes = {{"drone-a-hash", "drone-b-hash"}};
    const aerosim::ReplayRunResult run_a = aerosim::replay_session(
            make_session(atmosphere_a), configs, "settings-manifest-v1", hashes);
    const aerosim::ReplayRunResult run_b = aerosim::replay_session(
            make_session(atmosphere_b), configs, "settings-manifest-v1", hashes);
    aerosim::ReplaySessionRecorder incomplete(42, "settings-manifest-v1");
    if (incomplete.record_environment(0, replace_once(atmosphere_a, "\"seed\":11", "\"seed_missing\":11")) ||
            !run_a.ok || !run_b.ok ||
            run_a.final_state.upper.position.x == run_b.final_state.upper.position.x) {
        return false;
    }
    return true;
}

bool test_checkpoint_round_trip_preserves_atmosphere() {
    aerosim::ReplaySessionRecorder recorder(42, "settings-manifest-v1");
    aerosim::DualAircraftState state;
    if (!recorder.add_vehicle("DroneA", "drone-a-hash", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "drone-b-hash", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(23)) ||
            !recorder.record_checkpoint(1000, state) ||
            !recorder.finish(2000, "completed")) {
        return false;
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(
            recorder.serialize(), "settings-manifest-v1");
    return loaded.ok && loaded.session.checkpoints.size() == 1 &&
            loaded.session.checkpoints[0].environment_json == complete_atmosphere(23);
}

bool test_reset_replay_restores_environment_before_checkpoint() {
    aerosim::ReplaySessionRecorder recorder(42, "settings-manifest-v1");
    const std::string pre_reset_environment = complete_atmosphere(23);
    const std::string reset_environment = complete_atmosphere(47);
    aerosim::DualAircraftState reset_state;
    if (!recorder.add_vehicle("DroneA", "drone-a-hash", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "drone-b-hash", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, pre_reset_environment) ||
            !recorder.record_simulation_operation(1000, aerosim::ReplaySimulationOperation::Reset) ||
            !recorder.record_environment(1000, reset_environment) ||
            !recorder.record_checkpoint(1000, reset_state) || !recorder.finish(2000, "completed")) {
        return false;
    }
    const aerosim::ReplaySession &session = recorder.session();
    if (session.events.size() != 3 ||
            session.events[1].simulation_operation != aerosim::ReplaySimulationOperation::Reset ||
            session.events[2].environment_json != reset_environment) {
        return false;
    }
    const aerosim::SimulationConfig config = replay_test_config();
    const aerosim::DualAircraftConfig configs{config, config};
    const std::array<std::string, 2> hashes = {{"drone-a-hash", "drone-b-hash"}};
    const aerosim::ReplayRunResult replayed = aerosim::replay_session(
            session, configs, "settings-manifest-v1", hashes);
    return replayed.ok && replayed.environment_json == reset_environment && replayed.checkpoints.size() == 1 &&
            replayed.checkpoints[0].environment_json == reset_environment;
}

bool test_checkpoint_round_trip_preserves_collision_and_scene_state() {
    aerosim::ReplaySessionRecorder recorder(42, "settings-manifest-v1");
    aerosim::CollisionContact contact;
    contact.touching = true;
    contact.normal = {0.0, 1.0, 0.0};
    contact.impulse = {0.0, 2.0, 0.0};
    contact.restitution = 0.25;
    contact.has_resolved_state = true;
    contact.resolved_velocity = {1.0, 2.0, 3.0};
    contact.resolved_angular_velocity = {4.0, 5.0, 6.0};
    contact.max_kinetic_energy_joules = 7.0;
    aerosim::DualAircraftState state;
    if (!recorder.add_vehicle("DroneA", "drone-a-hash", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "drone-b-hash", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(23)) ||
            !recorder.record_collision(1000, "DroneB", contact, aerosim::ReplayControllerAuthority::Jolt) ||
            !recorder.record_scene_object(1000, aerosim::ReplaySceneObjectOperation::Spawn,
                    "crate", "primitive_box", {1.0, 2.0, 3.0}) ||
            !recorder.record_checkpoint(1000, state) || !recorder.finish(2000, "completed")) {
        return false;
    }

    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(
            recorder.serialize(), "settings-manifest-v1");
    if (!loaded.ok || loaded.session.checkpoints.size() != 1 ||
            loaded.session.checkpoints[0].collisions[1].contact.restitution != 0.25 ||
            loaded.session.checkpoints[0].scene_objects.size() != 1 ||
            loaded.session.checkpoints[0].scene_objects[0].name != "crate" ||
            loaded.session.checkpoints[0].environment_json != complete_atmosphere(23)) {
        return false;
    }

    aerosim::ReplaySession collision_changed = loaded.session;
    collision_changed.checkpoints[0].collisions[1].contact.restitution = 0.5;
    const aerosim::ReplayDivergence collision_divergence = aerosim::compare_replay_sessions(
            loaded.session, collision_changed);
    if (!collision_divergence.diverged || collision_divergence.vehicle_name != "DroneB" ||
            collision_divergence.field != "checkpoint.collision.restitution") {
        return false;
    }
    aerosim::ReplaySession scene_changed = loaded.session;
    scene_changed.checkpoints[0].scene_objects[0].position.x = 2.0;
    const aerosim::ReplayDivergence scene_divergence = aerosim::compare_replay_sessions(loaded.session, scene_changed);
    return scene_divergence.diverged && scene_divergence.field == "checkpoint.scene_object.position.x";
}

bool test_sparse_checkpoint_schedule() {
    aerosim::ReplaySessionRecorder recorder(29, "manifest");
    aerosim::FlightCommand command;
    command.throttle = 0.8;
    if (!recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(29)) ||
            !recorder.record_command(0, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_command(0, "DroneB", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_command(10000, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_command(10000, "DroneB", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.finish(30000, "completed")) {
        return false;
    }
    aerosim::SimulationConfig config = replay_test_config();
    config.gravity_mps2 = 1.0;
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = 4.0;
    const std::array<std::string, 2> hashes = {{"hash-a", "hash-b"}};
    aerosim::ReplaySession session = recorder.session();
    const aerosim::ReplayRunResult dense = aerosim::replay_session(
            session, {config, config}, "manifest", hashes);
    if (!dense.ok) {
        return false;
    }
    const auto at_10000 = std::find_if(dense.checkpoints.begin(), dense.checkpoints.end(), [](const auto &checkpoint) {
        return checkpoint.timestamp_us == 10000;
    });
    const auto at_30000 = std::find_if(dense.checkpoints.rbegin(), dense.checkpoints.rend(), [](const auto &checkpoint) {
        return checkpoint.timestamp_us == 30000;
    });
    if (at_10000 == dense.checkpoints.end() || at_30000 == dense.checkpoints.rend()) {
        return false;
    }
    session.checkpoints = {*at_10000, *at_30000};
    const aerosim::ReplayRunResult sparse = aerosim::replay_session(
            session, {config, config}, "manifest", hashes);
    aerosim::ReplayRunResult expected = sparse;
    expected.checkpoints = session.checkpoints;
    return sparse.ok && sparse.checkpoints.size() == session.checkpoints.size() &&
            sparse.checkpoints[0].timestamp_us == 10000 && sparse.checkpoints[1].timestamp_us == 30000 &&
            !aerosim::compare_replay_runs(expected, sparse).diverged;
}

bool test_complete_session_schema() {
    aerosim::ReplaySessionRecorder recorder(42, "settings-manifest-v1");
    if (!recorder.add_vehicle("DroneA", "drone-a-hash", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "drone-b-hash", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(17))) {
        return false;
    }

    aerosim::FlightCommand command;
    command.throttle = 0.55;
    if (!recorder.record_async_command(0, "DroneA", "task-a", "moveByVelocity", aerosim::ReplayAsyncLifecycle::Submitted) ||
            !recorder.record_async_command(0, "DroneB", "task-a", "hover", aerosim::ReplayAsyncLifecycle::Submitted) ||
            !recorder.record_async_command(1000, "DroneA", "task-a", "moveByVelocity", aerosim::ReplayAsyncLifecycle::Accepted) ||
            !recorder.record_async_command(1000, "DroneB", "task-a", "hover", aerosim::ReplayAsyncLifecycle::Accepted) ||
            !recorder.record_command(1000, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_command(1000, "DroneB", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_simulation_operation(2000, aerosim::ReplaySimulationOperation::Pause) ||
            !recorder.record_simulation_operation(3000, aerosim::ReplaySimulationOperation::StepFrames, 2) ||
            !recorder.record_async_command(4000, "DroneA", "task-a", "moveByVelocity", aerosim::ReplayAsyncLifecycle::Completed) ||
            !recorder.record_async_command(4000, "DroneB", "task-a", "hover", aerosim::ReplayAsyncLifecycle::Completed)) {
        return false;
    }

    aerosim::CollisionContact contact;
    contact.touching = true;
    contact.normal = {0.0, 1.0, 0.0};
    contact.impulse = {0.0, 2.0, 0.0};
    if (!recorder.record_collision(5000, "DroneB", contact, aerosim::ReplayControllerAuthority::Jolt) ||
            !recorder.record_scene_object(6000, aerosim::ReplaySceneObjectOperation::Spawn,
                    "crate", "primitive_box", {1.0, 2.0, 3.0}) ||
            !recorder.record_environment(7000, complete_atmosphere(18)) ||
            !recorder.record_simulation_operation(8000, aerosim::ReplaySimulationOperation::Respawn) ||
            !recorder.finish(9000, "completed")) {
        return false;
    }

    const std::string serialized = recorder.serialize();
    if (serialized.empty() || serialized.find("\"schema_version\":4") == std::string::npos ||
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
            loaded.session.events[2].vehicle_name != "DroneB" ||
            loaded.session.events[8].simulation_value != 2 ||
            loaded.session.events[11].collision.authority != aerosim::ReplayControllerAuthority::Jolt ||
            loaded.session.events[12].object_name != "crate" ||
            loaded.session.events[13].environment_json.find("\"seed\":18") == std::string::npos ||
            loaded.session.termination_reason != "completed") {
        return false;
    }

    const aerosim::ReplayLoadResult mismatched_manifest = aerosim::load_replay_session(serialized, "other-manifest");
    if (mismatched_manifest.ok || mismatched_manifest.diagnostic.code != aerosim::ReplayDiagnosticCode::IncompatibleManifest) {
        return false;
    }
    const aerosim::ReplayLoadResult unsupported = aerosim::load_replay_session(
        replace_once(serialized, "\"schema_version\":4", "\"schema_version\":99"));
    if (unsupported.ok || unsupported.diagnostic.code != aerosim::ReplayDiagnosticCode::UnsupportedSchema) {
        return false;
    }
    const aerosim::ReplayLoadResult schema_v2 = aerosim::load_replay_session(
        replace_once(serialized, "\"schema_version\":4", "\"schema_version\":2"));
    if (schema_v2.ok || schema_v2.diagnostic.code != aerosim::ReplayDiagnosticCode::UnsupportedSchema) {
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
    const aerosim::ReplayLoadResult missing_vehicle = aerosim::load_replay_session(
            replace_once(serialized, "\"vehicle\":\"DroneA\"", "\"vehicle_missing\":\"DroneA\""));
    if (missing_vehicle.ok || missing_vehicle.diagnostic.code != aerosim::ReplayDiagnosticCode::InvalidIdentity) {
        return false;
    }
    const aerosim::ReplayLoadResult exact_large_seed = aerosim::load_replay_session(
            replace_once(serialized, "\"seed\":42", "\"seed\":9007199254740993"));
    if (!exact_large_seed.ok || exact_large_seed.session.seed != 9007199254740993ULL) {
        return false;
    }
    const aerosim::ReplayLoadResult malformed_number = aerosim::load_replay_session(
            replace_once(serialized, "\"seed\":42", "\"seed\":01"));
    if (malformed_number.ok || malformed_number.diagnostic.code != aerosim::ReplayDiagnosticCode::Corrupt) {
        return false;
    }
    const aerosim::ReplayLoadResult missing_atmosphere_seed = aerosim::load_replay_session(
            replace_once(serialized, "\"seed\":17", "\"seed_missing\":17"));
    if (missing_atmosphere_seed.ok ||
            missing_atmosphere_seed.diagnostic.code != aerosim::ReplayDiagnosticCode::Corrupt) {
        return false;
    }
    aerosim::DualAircraftConfig config{replay_test_config(), replay_test_config()};
    const std::array<std::string, 2> config_hashes = {{"drone-a-hash", "drone-b-hash"}};
    const aerosim::ReplayRunResult first_run = aerosim::replay_session(recorder.session(), config, "settings-manifest-v1", config_hashes);
    const aerosim::ReplayRunResult second_run = aerosim::replay_session(recorder.session(), config, "settings-manifest-v1", config_hashes);
    if (!first_run.ok || !second_run.ok || first_run.final_clock.total_substeps != second_run.final_clock.total_substeps ||
            first_run.final_state.upper.position.x != second_run.final_state.upper.position.x ||
            first_run.final_state.lower.position.y != second_run.final_state.lower.position.y) {
        return false;
    }
    if (aerosim::replay_session(recorder.session(), config, "", config_hashes).ok ||
            aerosim::replay_session(recorder.session(), config, "settings-manifest-v1", {{"", "drone-b-hash"}}).ok) {
        return false;
    }
    if (aerosim::compare_replay_runs(first_run, second_run).diverged) {
        return false;
    }
    aerosim::ReplaySession mismatched_config = recorder.session();
    mismatched_config.vehicles[1].config_json = "{\"mass_kg\":1.0,\"gravity_mps2\":1.0}";
    const aerosim::ReplayRunResult config_mismatch = aerosim::replay_session(
            mismatched_config, config, "settings-manifest-v1", config_hashes);
    if (config_mismatch.ok || config_mismatch.diagnostic.code != aerosim::ReplayDiagnosticCode::IncompatibleManifest) {
        return false;
    }
    aerosim::ReplaySession collision_mismatch = recorder.session();
    collision_mismatch.events[11].collision.contact.restitution = 0.25;
    const aerosim::ReplayDivergence collision_divergence = aerosim::compare_replay_sessions(
            recorder.session(), collision_mismatch);
    if (!collision_divergence.diverged || collision_divergence.timestamp_us != 5000 ||
            collision_divergence.vehicle_name != "DroneB" || collision_divergence.field != "collision.restitution" ||
            collision_divergence.expected != "0" || collision_divergence.actual != "0.25") {
        return false;
    }
    aerosim::ReplaySession invalid_collision_authority = recorder.session();
    invalid_collision_authority.events[11].collision.authority = aerosim::ReplayControllerAuthority::FlightCore;
    const aerosim::ReplayRunResult rejected_collision_authority = aerosim::replay_session(
            invalid_collision_authority, config, "settings-manifest-v1", config_hashes);
    if (rejected_collision_authority.ok || rejected_collision_authority.diagnostic.code != aerosim::ReplayDiagnosticCode::InvalidSession) {
        return false;
    }
    aerosim::ReplaySession scene_mismatch = recorder.session();
    scene_mismatch.events[12].object_orientation.w = 0.5;
    const aerosim::ReplayDivergence scene_divergence = aerosim::compare_replay_sessions(
            recorder.session(), scene_mismatch);
    if (!scene_divergence.diverged || scene_divergence.timestamp_us != 6000 ||
            scene_divergence.field != "scene_object.orientation.w") {
        return false;
    }
    bool found_collision_checkpoint = false;
    aerosim::ReplayRunResult checkpoint_mismatch = second_run;
    for (aerosim::ReplayRunCheckpoint &checkpoint : checkpoint_mismatch.checkpoints) {
        if (checkpoint.collisions[1].contact.touching) {
            checkpoint.collisions[1].contact.restitution += 0.25;
            found_collision_checkpoint = true;
            break;
        }
    }
    if (!found_collision_checkpoint) {
        return false;
    }
    const aerosim::ReplayDivergence checkpoint_divergence = aerosim::compare_replay_runs(
            first_run, checkpoint_mismatch);
    if (!checkpoint_divergence.diverged || checkpoint_divergence.vehicle_name != "DroneB" ||
            checkpoint_divergence.field != "collision.restitution") {
        return false;
    }
    aerosim::ReplayRunResult controller_mismatch = second_run;
    controller_mismatch.checkpoints.front().controllers[0].target_rate_frd.x += 0.25;
    const aerosim::ReplayDivergence controller_divergence = aerosim::compare_replay_runs(first_run, controller_mismatch);
    if (!controller_divergence.diverged || controller_divergence.field != "checkpoint.controller[0].target_rate_frd.x") {
        return false;
    }
    aerosim::ReplayRunResult motor_mismatch = second_run;
    motor_mismatch.checkpoints.front().first_response_substeps[0].state.motor_thrust_newtons[0] += 0.25;
    const aerosim::ReplayDivergence motor_divergence = aerosim::compare_replay_runs(first_run, motor_mismatch);
    if (!motor_divergence.diverged || motor_divergence.field != "checkpoint.controller[0].motor[0]") {
        return false;
    }
    aerosim::ReplayRunResult propwash_mismatch = second_run;
    propwash_mismatch.checkpoints.front().first_response_substeps[0].state.propwash_disturbance_rad_s2.x += 0.25;
    const aerosim::ReplayDivergence propwash_divergence = aerosim::compare_replay_runs(first_run, propwash_mismatch);
    if (!propwash_divergence.diverged || propwash_divergence.field != "checkpoint.controller[0].first_response.propwash.x") {
        return false;
    }
    aerosim::ReplayRunResult signed_zero_mismatch = second_run;
    signed_zero_mismatch.checkpoints.front().controllers[0].target_angle_frd.x = -0.0;
    const aerosim::ReplayDivergence signed_zero_divergence = aerosim::compare_replay_runs(first_run, signed_zero_mismatch);
    if (!signed_zero_divergence.diverged || signed_zero_divergence.field != "checkpoint.controller[0].target_angle_frd.x") {
        return false;
    }
    aerosim::ReplayRunResult clock_mismatch = second_run;
    ++clock_mismatch.checkpoints.front().clocks[0].total_substeps;
    const aerosim::ReplayDivergence clock_divergence = aerosim::compare_replay_runs(first_run, clock_mismatch);
    if (!clock_divergence.diverged || clock_divergence.field != "checkpoint.controller[0].mode_or_clock") {
        return false;
    }
    aerosim::ReplayRunResult divergent_run = second_run;
    divergent_run.final_state.upper.position.x += 0.25;
    const aerosim::ReplayDivergence run_divergence = aerosim::compare_replay_runs(first_run, divergent_run, 0.01);
    if (!run_divergence.diverged || run_divergence.field != "upper.position.x" ||
            run_divergence.expected == run_divergence.actual || run_divergence.tolerance != 0.01) {
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
    if (!recorder.record_async_command(4, "DroneB", "other-task", "hover", aerosim::ReplayAsyncLifecycle::Submitted) ||
            recorder.finish(5, "incomplete") ||
            recorder.diagnostic().code != aerosim::ReplayDiagnosticCode::InvalidLifecycle) {
        return false;
    }
    return true;
}

bool test_simulation_time_replay_contract() {
    aerosim::ReplaySessionRecorder recorder(11, "manifest");
    if (!recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(11)) ||
            !recorder.record_command(0, "DroneA", {}, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_command(0, "DroneB", {}, aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.record_simulation_operation(0, aerosim::ReplaySimulationOperation::StepSeconds, 0.0005) ||
            !recorder.finish(1000000, "completed")) {
        return false;
    }
    aerosim::DualAircraftConfig config{replay_test_config(), replay_test_config()};
    const aerosim::ReplayRunResult run = aerosim::replay_session(recorder.session(), config, "manifest", {{"hash-a", "hash-b"}});
    if (!run.ok || run.final_clock.total_substeps != 101) {
        return false;
    }
    aerosim::ReplaySessionRecorder oversized(12, "manifest");
    if (!oversized.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !oversized.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !oversized.record_environment(0, complete_atmosphere(12)) ||
            !oversized.record_command(0, "DroneA", {}, aerosim::ReplayControllerAuthority::FlightCore) ||
            !oversized.record_command(0, "DroneB", {}, aerosim::ReplayControllerAuthority::FlightCore) ||
            !oversized.record_simulation_operation(0, aerosim::ReplaySimulationOperation::StepSeconds, 11000.0) ||
            !oversized.finish(11000000000ULL, "completed")) {
        return false;
    }
    const aerosim::ReplayRunResult rejected = aerosim::replay_session(oversized.session(), config, "manifest", {{"hash-a", "hash-b"}});
    return !rejected.ok && rejected.diagnostic.code == aerosim::ReplayDiagnosticCode::InvalidSession;
}

bool test_replay_command_modes_and_inactive_vehicle() {
    aerosim::ReplaySessionRecorder recorder(19, "manifest");
    if (!recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}", aerosim::ReplayControllerAuthority::FlightCore) ||
            !recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}", aerosim::ReplayControllerAuthority::Px4External) ||
            !recorder.record_environment(0, complete_atmosphere(19))) {
        return false;
    }
    aerosim::FlightCommand angle;
    angle.throttle = 0.4;
    angle.vertical_velocity_mps = 0.1;
    angle.heading_hold_enabled = true;
    angle.position_hold_enabled = true;
    aerosim::AcroCommand acro;
    acro.throttle = 0.45;
    acro.roll_stick = 0.1;
    acro.pitch_stick = -0.2;
    acro.yaw_stick = 0.3;
    acro.rates = {1.0, 0.7, 0.1};
    aerosim::MotorCommands actuators{{0.2, 0.3, 0.4, 0.5}};
    if (!recorder.record_actuator_command(0, "DroneB", actuators, aerosim::ReplayControllerAuthority::Px4External) ||
            !recorder.record_mode_command(0, "DroneA", aerosim::ReplayCommandMode::Angle, angle, acro,
                    aerosim::ReplayControllerAuthority::FlightCore, 1.0) ||
            !recorder.record_mode_command(10000, "DroneA", aerosim::ReplayCommandMode::Acro, angle, acro,
                    aerosim::ReplayControllerAuthority::FlightCore, 1.1) ||
            !recorder.record_mode_command(20000, "DroneA", aerosim::ReplayCommandMode::AltitudeHold, angle, acro,
                    aerosim::ReplayControllerAuthority::FlightCore, 1.2) ||
            !recorder.finish(30000, "completed")) {
        return false;
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(recorder.serialize(), "manifest");
    if (!loaded.ok || loaded.session.events.size() != 5 ||
            loaded.session.events[1].command_mode != aerosim::ReplayCommandMode::Actuator ||
            loaded.session.events[1].actuator_commands != actuators.normalized ||
            loaded.session.events[3].command_mode != aerosim::ReplayCommandMode::Acro ||
            loaded.session.events[4].command_mode != aerosim::ReplayCommandMode::AltitudeHold ||
            loaded.session.events[4].measured_altitude_m != 1.2 ||
            loaded.session.events[4].command.vertical_velocity_mps != 0.1 ||
            !loaded.session.events[4].command.heading_hold_enabled ||
            !loaded.session.events[4].command.position_hold_enabled) {
        return false;
    }
    const aerosim::SimulationConfig config = replay_test_config();
    const aerosim::ReplayRunResult run = aerosim::replay_session(
            loaded.session, {config, config}, "manifest", {{"hash-a", "hash-b"}});
    if (!run.ok) {
        return false;
    }

    aerosim::ReplaySessionRecorder inactive(20, "manifest");
    if (!inactive.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !inactive.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !inactive.record_environment(0, complete_atmosphere(20)) ||
            !inactive.record_command(0, "DroneA", {}, aerosim::ReplayControllerAuthority::FlightCore) ||
            !inactive.finish(100000, "completed")) {
        return false;
    }
    aerosim::SimulationConfig lower_config = replay_test_config();
    lower_config.initial_state.velocity.y = 1.0;
    const aerosim::ReplayRunResult inactive_run = aerosim::replay_session(
            inactive.session(), {config, lower_config}, "manifest", {{"hash-a", "hash-b"}});
    return inactive_run.ok && inactive_run.final_state.lower.position.y == 0.0 &&
            inactive_run.final_state.lower.velocity.y == 1.0;
}

bool test_first_divergence_report() {
    aerosim::ReplaySessionRecorder recorder(7, "manifest");
    recorder.add_vehicle("DroneA", "hash-a", "{}");
    recorder.add_vehicle("DroneB", "hash-b", "{}");
    recorder.record_environment(0, complete_atmosphere(7));
    aerosim::FlightCommand command;
    recorder.record_command(1000, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore);
    recorder.finish(2000, "completed");
    const aerosim::ReplaySession expected = recorder.session();
    aerosim::ReplaySession actual = expected;
    actual.events[1].command.throttle = 0.25;
    const aerosim::ReplayDivergence divergence = aerosim::compare_replay_sessions(expected, actual);
    return divergence.diverged && divergence.timestamp_us == 1000 &&
            divergence.vehicle_name == "DroneA" && divergence.field == "command.throttle" &&
            divergence.expected == "0" && divergence.actual == "0.25" && divergence.tolerance == 0.0;
}

bool test_tuning_replay_contract() {
    aerosim::ReplaySessionRecorder recorder(31, "manifest");
    if (!recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(31)) ||
            !recorder.record_tuning(1000, "DroneA", 7, 3, "simpleflight.rate_p", 3.0, 2.0, true) ||
            !recorder.record_tuning(1000, "DroneA", 8, 3, "simpleflight.angle_p", 16.0, 16.0, false) ||
            !recorder.record_tuning(1000, "DroneA", 9, 3, "simpleflight.rate_i", 0.031, 0.031, false) ||
            !recorder.record_tuning(1000, "DroneA", 10, 3, "simpleflight.rate_d", 0.007, 0.007, false) ||
            !recorder.finish(2000, "completed")) {
        return false;
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(recorder.serialize(), "manifest");
    if (!loaded.ok || loaded.session.events.size() != 5 || loaded.session.events[1].type != aerosim::ReplayEventType::Tuning ||
            loaded.session.events[1].tuning_request_seq != 7 || loaded.session.events[1].tuning_commit_id != 3 ||
            loaded.session.events[1].tuning_parameter != "simpleflight.rate_p" ||
            loaded.session.events[1].tuning_committed_value != 2.0 || !loaded.session.events[1].tuning_clamped) {
        return false;
    }
    const aerosim::SimulationConfig tuning_config = replay_test_config();
    const aerosim::ReplayRunResult tuning_run = aerosim::replay_session(
            loaded.session, {tuning_config, tuning_config}, "manifest", {{"hash-a", "hash-b"}});
    if (!tuning_run.ok) {
        return false;
    }
    aerosim::ReplaySession changed = loaded.session;
    changed.events[1].tuning_committed_value = 1.0;
    const aerosim::ReplayDivergence divergence = aerosim::compare_replay_sessions(loaded.session, changed);
    if (!divergence.diverged || divergence.field != "tuning") {
        return false;
    }

    aerosim::ReplaySessionRecorder ordered_recorder(32, "manifest");
    aerosim::FlightCommand command;
    command.throttle = 0.55;
    command.roll_degrees = 12.0;
    if (!ordered_recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !ordered_recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !ordered_recorder.record_environment(0, complete_atmosphere(32)) ||
            !ordered_recorder.record_command(0, "DroneA", command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !ordered_recorder.record_tuning(1000, "DroneA", 8, 1, "simpleflight.rate_p", 2.0, 2.0, false) ||
            !ordered_recorder.record_simulation_operation(1000, aerosim::ReplaySimulationOperation::StepFrames, 1) ||
            !ordered_recorder.finish(2000, "completed")) {
        return false;
    }
    aerosim::ReplaySession reversed = ordered_recorder.session();
    std::swap(reversed.events[2], reversed.events[3]);
    const aerosim::SimulationConfig config = replay_test_config();
    const aerosim::ReplayRunResult ordered_run = aerosim::replay_session(
            ordered_recorder.session(), {config, config}, "manifest", {{"hash-a", "hash-b"}});
    const aerosim::ReplayRunResult reversed_run = aerosim::replay_session(
            reversed, {config, config}, "manifest", {{"hash-a", "hash-b"}});
    const aerosim::ReplayDivergence order_divergence = aerosim::compare_replay_runs(ordered_run, reversed_run);
    return ordered_run.ok && reversed_run.ok && order_divergence.diverged;
}

bool test_quick_adjust_binding_replay_contract() {
    const std::string empty_profile = R"({"schema_version":1,"slots":[null,null,null,null,null,null,null,null]})";
    const std::string bound_profile = R"({"schema_version":1,"slots":[{"parameter":"simpleflight.rate_p","binding_type":"key_pair","negative_key":81,"positive_key":69,"mode":"relative","subset_min":0.6,"subset_max":1.4,"deadzone":0.05,"step":0.01,"rate_limit":30},null,null,null,null,null,null,null]})";
    aerosim::ReplaySessionRecorder recorder(246, "manifest");
    if (!recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            !recorder.record_environment(0, complete_atmosphere(246)) ||
            !recorder.record_quick_adjust_binding(100, bound_profile) ||
            !recorder.record_quick_adjust_binding(200, empty_profile) ||
            !recorder.record_quick_adjust_binding(300, bound_profile) ||
            !recorder.record_tuning(400, "DroneA", 12, 4, "simpleflight.rate_p", 1.2, 1.2, false, "quick_adjust", 0) ||
            !recorder.finish(500, "completed")) {
        return false;
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(recorder.serialize(), "manifest");
    if (!loaded.ok || loaded.session.schema_version != 4 || loaded.session.events.size() != 5 ||
            loaded.session.events[1].type != aerosim::ReplayEventType::QuickAdjustBinding ||
            loaded.session.events[1].quick_adjust_profile_json != bound_profile ||
            loaded.session.events[2].quick_adjust_profile_json != empty_profile ||
            loaded.session.events[4].tuning_source != "quick_adjust" ||
            loaded.session.events[4].tuning_quick_adjust_slot != 0) {
        return false;
    }
    if (aerosim::compare_replay_sessions(recorder.session(), loaded.session).diverged) {
        return false;
    }
    const aerosim::SimulationConfig config = replay_test_config();
    const aerosim::ReplayRunResult run = aerosim::replay_session(
            loaded.session, {config, config}, "manifest", {{"hash-a", "hash-b"}});
    if (!run.ok) {
        return false;
    }
    aerosim::ReplaySession invalid = recorder.session();
    invalid.events[1].quick_adjust_profile_json = R"({"schema_version":1,"slots":[null]})";
    if (aerosim::load_replay_session(aerosim::serialize_replay_session(invalid), "manifest").ok) {
        return false;
    }
    aerosim::ReplaySession vehicle_bound = recorder.session();
    vehicle_bound.events[1].vehicle_name = "DroneA";
    return !aerosim::load_replay_session(aerosim::serialize_replay_session(vehicle_bound), "manifest").ok;
}

bool test_checked_replay_batches() {
    aerosim::SimulationConfig config;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    configure_power_model(config);

    const aerosim::ReplayBatchResult empty = aerosim::replay_angle_mode_batch(config, {});
    if (empty.status != aerosim::StepStatus::Ok || !empty.rows.empty() ||
            empty.failed_frame != aerosim::kNoFailedReplayFrame) {
        return false;
    }
    aerosim::FlightCommand command;
    const aerosim::ReplayBatchResult zero = aerosim::replay_angle_mode_seconds_batch(config, command, 0.0);
    const aerosim::ReplayBatchResult negative = aerosim::replay_angle_mode_seconds_batch(config, command, -0.1);
    const aerosim::ReplayBatchResult non_finite = aerosim::replay_angle_mode_seconds_batch(
            config, command, std::numeric_limits<double>::infinity());
    if (zero.status != aerosim::StepStatus::Ok || !zero.rows.empty() ||
            negative.status != aerosim::StepStatus::InvalidConfig ||
            non_finite.status != aerosim::StepStatus::InvalidConfig) {
        return false;
    }

    aerosim::RecordedInputSequence invalid;
    invalid.frames.push_back(command);
    invalid.frames.push_back(command);
    invalid.frames[1].throttle = std::numeric_limits<double>::quiet_NaN();
    const aerosim::ReplayBatchResult failed = aerosim::replay_angle_mode_batch(config, invalid);
    if (failed.status != aerosim::StepStatus::InvalidCommand || !failed.rows.empty() || failed.failed_frame != 1) {
        return false;
    }
    aerosim::RecordedInputSequence out_of_domain;
    out_of_domain.frames.push_back(command);
    out_of_domain.frames[0].throttle = 2.0;
    const aerosim::ReplayBatchResult out_of_domain_failed = aerosim::replay_angle_mode_batch(config, out_of_domain);
    if (out_of_domain_failed.status != aerosim::StepStatus::InvalidCommand || !out_of_domain_failed.rows.empty() ||
            out_of_domain_failed.failed_frame != 0) {
        return false;
    }
    aerosim::ReplaySessionRecorder recorder(23, "manifest");
    if (!recorder.add_vehicle("DroneA", "hash-a", "{\"mass_kg\":1.0}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{\"mass_kg\":1.0}") ||
            recorder.record_command(0, "DroneA", out_of_domain.frames[0], aerosim::ReplayControllerAuthority::FlightCore)) {
        return false;
    }
    const aerosim::ReplayBatchResult oversized = aerosim::replay_angle_mode_seconds_batch(
            config, command, static_cast<double>(aerosim::kMaxBatchTrajectoryFrames) / config.physics_hz + 1.0);
    const aerosim::ReplayBatchResult overflow = aerosim::replay_angle_mode_seconds_batch(
            config, command, std::numeric_limits<double>::max());
    return oversized.status == aerosim::StepStatus::ResourceLimitExceeded && oversized.rows.empty() &&
            oversized.failed_frame == aerosim::kNoFailedReplayFrame &&
            overflow.status == aerosim::StepStatus::ResourceLimitExceeded && overflow.rows.empty() &&
            overflow.failed_frame == aerosim::kNoFailedReplayFrame;
}

bool test_schema_v3_controller_snapshot_divergence() {
    aerosim::ReplayRunCheckpoint checkpoint;
    checkpoint.timestamp_us = 1;
    checkpoint.controllers[0].target_rate_frd.x = 0.25;
    checkpoint.controllers[0].rate_integral[1] = 0.5;
    checkpoint.controllers[0].motor_saturation_latched[2] = true;
    checkpoint.clocks[0].total_substeps = 1;
    checkpoint.first_response_substeps[0].substeps = 1;
    aerosim::ReplaySessionRecorder checkpoint_recorder(1, "manifest");
    if (!checkpoint_recorder.add_vehicle("DroneA", "hash-a", "{}") ||
            !checkpoint_recorder.add_vehicle("DroneB", "hash-b", "{}") ||
            !checkpoint_recorder.record_environment(0, complete_atmosphere()) ||
            !checkpoint_recorder.record_checkpoint(1, checkpoint) ||
            !checkpoint_recorder.finish(1, "completed")) {
        return false;
    }
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(checkpoint_recorder.serialize(), "manifest");
    if (!loaded.ok || loaded.session.schema_version != 4 ||
            loaded.session.checkpoints[0].controllers[0].rate_integral[1] != 0.5 ||
            !loaded.session.checkpoints[0].controllers[0].motor_saturation_latched[2]) {
        return false;
    }
    aerosim::ReplaySession changed = loaded.session;
    changed.checkpoints[0].controllers[0].target_rate_frd.x += 0.25;
    const aerosim::ReplayDivergence divergence = aerosim::compare_replay_sessions(loaded.session, changed);
    return divergence.diverged && divergence.field == "checkpoint.controller[0].target_rate_frd.x";
}

bool test_schema_v3_checkpoint_requires_complete_state() {
    aerosim::ReplaySessionRecorder recorder(42, "manifest");
    aerosim::ReplayRunCheckpoint checkpoint;
    checkpoint.first_response_substeps[0].propwash_disturbance_rad_s2 = {1.0, -0.0, 3.0};
    if (!recorder.add_vehicle("DroneA", "hash-a", "{}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{}") ||
            !recorder.record_environment(0, complete_atmosphere(23)) ||
            !recorder.record_checkpoint(1, checkpoint) || !recorder.finish(1, "completed")) {
        return false;
    }
    const std::string serialized = recorder.serialize();
    const std::string missing_collisions = replace_once(serialized, ",\"collisions\":[", ",\"missing_collisions\":[");
    const std::string missing_scene = replace_once(serialized, ",\"scene_objects\":[", ",\"missing_scene_objects\":[");
    const std::string missing_environment = replace_once(serialized, ",\"environment\":", ",\"missing_environment\":");
    const std::string missing_propwash = replace_once(serialized,
            "\"propwash_disturbance_rad_s2\":", "\"missing_propwash_disturbance_rad_s2\":");
    const std::string disagreeing_environment = replace_once(serialized, "\"seed\":23", "\"seed\":24");
    const aerosim::ReplayLoadResult loaded = aerosim::load_replay_session(serialized, "manifest");
    if (!loaded.ok || !same_sample_bits(loaded.session.checkpoints[0].first_response_substeps[0], checkpoint.first_response_substeps[0]) ||
            aerosim::load_replay_session(missing_collisions, "manifest").ok ||
            aerosim::load_replay_session(missing_scene, "manifest").ok ||
            aerosim::load_replay_session(missing_environment, "manifest").ok ||
            aerosim::load_replay_session(missing_propwash, "manifest").ok ||
            aerosim::load_replay_session(disagreeing_environment, "manifest").ok) {
        return false;
    }
    aerosim::ReplaySession changed = loaded.session;
    changed.checkpoints[0].first_response_substeps[0].propwash_disturbance_rad_s2.x = 2.0;
    const aerosim::ReplayDivergence divergence = aerosim::compare_replay_sessions(loaded.session, changed);
    return divergence.diverged && divergence.field == "checkpoint.controller[0].first_response.propwash_disturbance_rad_s2.x";
}

bool test_replay_rejects_collision_contacts_outside_live_domain() {
    aerosim::ReplaySessionRecorder recorder(42, "manifest");
    aerosim::CollisionContact contact;
    contact.touching = true;
    contact.normal = {0.0, 1.0, 0.0};
    contact.restitution = 0.25;
    if (!recorder.add_vehicle("DroneA", "hash-a", "{}") ||
            !recorder.add_vehicle("DroneB", "hash-b", "{}")) {
        return false;
    }

    aerosim::CollisionContact invalid = contact;
    invalid.restitution = 1.1;
    if (recorder.record_collision(0, "DroneA", invalid, aerosim::ReplayControllerAuthority::Jolt)) {
        return false;
    }
    if (!recorder.record_environment(0, complete_atmosphere(42)) ||
            !recorder.record_collision(0, "DroneA", contact, aerosim::ReplayControllerAuthority::Jolt) ||
            !recorder.record_checkpoint(0, aerosim::DualAircraftState{}) || !recorder.finish(1, "completed")) {
        return false;
    }

    const std::string serialized = recorder.serialize();
    const std::string invalid_event = replace_once(serialized, "\"restitution\":0.25", "\"restitution\":1.1");
    std::string invalid_checkpoint = serialized;
    const std::size_t checkpoint_restitution = invalid_checkpoint.rfind("\"restitution\":0.25");
    if (checkpoint_restitution == std::string::npos) {
        return false;
    }
    invalid_checkpoint.replace(checkpoint_restitution, std::strlen("\"restitution\":0.25"), "\"restitution\":1.1");
    return !aerosim::load_replay_session(invalid_event, "manifest").ok &&
            !aerosim::load_replay_session(invalid_checkpoint, "manifest").ok;
}

bool test_complete_replay_rejects_third_vehicle_before_collision_state() {
    aerosim::ReplaySessionRecorder recorder(42, "manifest");
    return recorder.add_vehicle("DroneA", "hash-a", "{}") &&
            recorder.add_vehicle("DroneB", "hash-b", "{}") &&
            !recorder.add_vehicle("DroneC", "hash-c", "{}") &&
            recorder.diagnostic().code == aerosim::ReplayDiagnosticCode::InvalidSession;
}

bool test_checked_replay_batch_samples_configured_wind_each_frame() {
    aerosim::SimulationConfig config = replay_test_config();
    config.physics_hz = 100;
    config.substep_hz = 100;
    config.body_drag.enabled = true;
    config.body_drag.drag_coefficient = {1.0, 1.0, 1.0};
    config.body_drag.frontal_area_m2 = {1.0, 1.0, 1.0};
    config.initial_state.position.y = 2.0;
    config.initial_state.velocity = {4.0, 0.0, 0.0};
    aerosim::WindConfig wind_config;
    wind_config.steady_wind_mps = {1.0, 0.0, 0.0};
    wind_config.shear_enabled = true;
    wind_config.shear_reference_height_m = 1.0;
    wind_config.shear_exponent = 1.0;
    aerosim::WindField wind_field;
    wind_field.configure(wind_config);
    aerosim::FlightCommand command;
    command.throttle = 0.5;
    const aerosim::ReplayBatchResult actual = aerosim::replay_angle_mode_seconds_batch(config, command, 0.03, wind_field);

    aerosim::RigidBodyState state = config.initial_state;
    aerosim::SimulationClock clock;
    aerosim::FlightController controller;
    controller.arm(0.0);
    std::vector<aerosim::TrajectorySample> expected;
    for (int frame = 0; frame < 3; ++frame) {
        aerosim::SimulationConfig frame_config = config;
        const double time_seconds = static_cast<double>(clock.total_substeps) / config.substep_hz;
        frame_config.wind_world_mps = wind_field.sample(time_seconds, state.position);
        frame_config.wind_turbulence_mps = wind_field.turbulence(time_seconds);
        const aerosim::StepResult step = controller.try_step_angle_mode(state, clock, frame_config, command, state.orientation);
        if (step.status != aerosim::StepStatus::Ok) {
            return false;
        }
        expected.push_back(step.sample);
    }
    return actual.status == aerosim::StepStatus::Ok && actual.rows.size() == expected.size() &&
            std::equal(actual.rows.begin(), actual.rows.end(), expected.begin(), same_sample_bits);
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
    aerosim::SimulationConfig first_response_config = replay_test_config();
    first_response_config.physics_hz = 240;
    first_response_config.substep_hz = 1000;
    aerosim::RigidBodyState first_response_state;
    aerosim::SimulationClock first_response_clock;
    aerosim::FlightController first_response_controller;
    first_response_controller.arm(0.0);
    aerosim::FlightCommand first_response_command;
    first_response_command.throttle = 0.7;
    first_response_command.roll_degrees = 3.0;
    const aerosim::TrajectorySample first_response_frame = first_response_controller.step_angle_mode(
            first_response_state, first_response_clock, first_response_config, first_response_command);
    if (first_response_frame.substeps != 4 || first_response_frame.first_substeps != 1 ||
            std::abs(first_response_frame.first_substep_time_seconds - 0.001) > 1e-12) {
        return fail("replay first response must capture the first 1 kHz substep rather than the frame endpoint");
    }
    aerosim::SimulationConfig artifact_config = standard_config;
    artifact_config.a6_propwash.enabled = true;
    artifact_config.a6_propwash.full_collective_angular_accel_rad_s2 = 12.0;
    artifact_config.a6_propwash.minimum_wake_entry_speed_mps = 0.001;
    artifact_config.a6_propwash.minimum_transverse_rate_rad_s = 0.001;
    aerosim::RigidBodyState artifact_state;
    artifact_state.velocity.y = -6.0;
    artifact_state.angular_velocity = {3.0, 4.0, 0.0};
    aerosim::SimulationClock artifact_clock;
    aerosim::FlightController artifact_controller;
    artifact_controller.arm(0.0);
    aerosim::FlightCommand artifact_command;
    artifact_command.throttle = 0.8;
    artifact_command.roll_degrees = 4.0;
    const aerosim::TrajectorySample artifact_response = artifact_controller.step_angle_mode(
            artifact_state, artifact_clock, artifact_config, artifact_command);
    aerosim::ReplayRunCheckpoint artifact_checkpoint;
    artifact_checkpoint.state = {artifact_state, artifact_state};
    artifact_checkpoint.controllers = {{artifact_controller.control_state(), artifact_controller.control_state()}};
    artifact_checkpoint.controllers[0].target_angle_frd.z = -0.0;
    artifact_checkpoint.clocks = {{artifact_clock, artifact_clock}};
    artifact_checkpoint.first_response_substeps = {{artifact_response, artifact_response}};
    aerosim::ReplaySessionRecorder artifact_recorder(91, "artifact-manifest");
    if (!artifact_recorder.add_vehicle("DroneA", "artifact-a", "{\"mass_kg\":1.0}") ||
            !artifact_recorder.add_vehicle("DroneB", "artifact-b", "{\"mass_kg\":1.0}") ||
            !artifact_recorder.record_environment(0, complete_atmosphere()) ||
            !artifact_recorder.record_command(0, "DroneA", artifact_command, aerosim::ReplayControllerAuthority::FlightCore) ||
            !artifact_recorder.record_checkpoint(1, artifact_checkpoint) || !artifact_recorder.finish(1, "completed")) {
        return fail("failed to create schema-v3 replay artifact checkpoint");
    }
    const aerosim::ReplayLoadResult artifact_loaded = aerosim::load_replay_session(
            artifact_recorder.serialize(), "artifact-manifest");
    if (!artifact_loaded.ok || artifact_loaded.session.checkpoints.size() != 1 ||
            artifact_loaded.session.checkpoints[0].first_response_substeps[0].substeps == 0 ||
            artifact_loaded.session.checkpoints[0].state.upper.propwash_disturbance_rad_s2.x == 0.0) {
        return fail("schema-v3 replay artifact must retain an actual response checkpoint");
    }
    if (!write_artifact(std::getenv("AEROSIM_REPLAY_ARTIFACT"), artifact_loaded.session)) {
        return fail("failed to write schema-v3 replay checkpoint artifact");
    }

    if (!test_complete_session_schema()) {
        return fail("complete-session replay schema must round-trip and diagnose load failures");
    }
    if (!test_session_identity_and_async_validation()) {
        return fail("complete-session replay must validate identities and async lifecycle transitions");
    }
    if (!test_simulation_time_replay_contract()) {
        return fail("complete-session replay must preserve simulation-time semantics and bounds");
    }
    if (!test_replay_command_modes_and_inactive_vehicle()) {
        return fail("complete-session replay must preserve command modes and inactive vehicle behavior");
    }
    if (!test_first_divergence_report()) {
        return fail("complete-session replay must report the first field divergence");
    }
    if (!test_tuning_replay_contract()) {
        return fail("complete-session replay must round-trip ordered tuning inputs");
    }
    if (!test_quick_adjust_binding_replay_contract()) {
        return fail("complete-session replay must round-trip Quick Adjust metadata and provenance");
    }
    if (!test_checked_replay_batches()) {
        return fail("replay batches must retain checked status, rows, and failed frame");
    }
    if (!test_schema_v3_controller_snapshot_divergence()) {
        return fail("schema-v3 replay must retain and compare controller checkpoint state");
    }
    if (!test_schema_v3_checkpoint_requires_complete_state()) {
        return fail("schema-v3 replay checkpoints must retain required state without environment masking");
    }
    if (!test_replay_rejects_collision_contacts_outside_live_domain()) {
        return fail("replay must reject collision contacts outside the live domain before execution");
    }
    if (!test_complete_replay_rejects_third_vehicle_before_collision_state()) {
        return fail("complete replay must reject a third vehicle before fixed collision state");
    }
    if (!test_checked_replay_batch_samples_configured_wind_each_frame()) {
        return fail("checked replay batches must sample configured wind for every frame");
    }
    if (!test_replay_reconstructs_seeded_atmosphere()) {
        return fail("replay must reconstruct seeded atmosphere inputs instead of static turbulence");
    }
    if (!test_checkpoint_round_trip_preserves_atmosphere()) {
        return fail("replay checkpoints must retain the captured atmosphere through serialization");
    }
    if (!test_reset_replay_restores_environment_before_checkpoint()) {
        return fail("replay Reset must retain its following environment baseline through application and checkpoints");
    }
    if (!test_checkpoint_round_trip_preserves_collision_and_scene_state()) {
        return fail("replay checkpoints must round-trip collision and scene state");
    }
    if (!test_sparse_checkpoint_schedule()) {
        return fail("replay v3 must preserve and compare the recorded sparse checkpoint schedule");
    }

    return EXIT_SUCCESS;
}
