#pragma once

#include "aerosim_collision.hpp"

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace aerosim {

struct RecordedInputSequence {
    std::string vehicle_name;
    std::vector<FlightCommand> frames;
};

struct ReplayDelta {
    double orientation_degrees = 0.0;
    double position_meters = 0.0;
};

constexpr std::int32_t kCompleteReplaySchemaVersion = 1;

enum class ReplayControllerAuthority {
    FlightCore,
    Jolt,
    Px4External,
};

enum class ReplayCommandMode {
    Angle,
    Acro,
    AltitudeHold,
};

enum class ReplayAsyncLifecycle {
    Submitted,
    Accepted,
    Completed,
    Cancelled,
    TimedOut,
};

enum class ReplaySimulationOperation {
    Pause,
    Resume,
    StepFrames,
    StepSeconds,
    Reset,
    Respawn,
};

enum class ReplaySceneObjectOperation {
    Spawn,
    Move,
    Destroy,
    Reset,
};

struct ReplayVehicleConfig {
    std::string name;
    std::string config_manifest_hash;
    std::string config_json;
    ReplayControllerAuthority controller_authority = ReplayControllerAuthority::FlightCore;
};

struct ReplayCollision {
    ReplayControllerAuthority authority = ReplayControllerAuthority::FlightCore;
    CollisionContact contact;
};

enum class ReplayEventType {
    Command,
    AsyncCommand,
    SimulationTime,
    Collision,
    SceneObject,
    Environment,
};

struct ReplayEvent {
    std::uint64_t timestamp_us = 0;
    ReplayEventType type = ReplayEventType::Command;
    std::string vehicle_name;
    ReplayControllerAuthority controller_authority = ReplayControllerAuthority::FlightCore;
    ReplayCommandMode command_mode = ReplayCommandMode::Angle;
    FlightCommand command;
    AcroCommand acro_command;
    std::string command_id;
    std::string command_method;
    ReplayAsyncLifecycle command_lifecycle = ReplayAsyncLifecycle::Submitted;
    ReplaySimulationOperation simulation_operation = ReplaySimulationOperation::Pause;
    double simulation_value = 0.0;
    ReplayCollision collision;
    ReplaySceneObjectOperation object_operation = ReplaySceneObjectOperation::Spawn;
    std::string object_name;
    std::string object_asset_id;
    Vec3 object_position;
    Quat object_orientation;
    std::string environment_json;
};

struct ReplaySceneObjectState {
    std::string name;
    std::string asset_id;
    Vec3 position;
    Quat orientation;
};

struct ReplayRunCheckpoint {
    std::uint64_t timestamp_us = 0;
    DualAircraftState state;
    std::array<ReplayCollision, 2> collisions;
    std::vector<ReplaySceneObjectState> scene_objects;
    std::string environment_json;
};

struct ReplaySession {
    std::int32_t schema_version = kCompleteReplaySchemaVersion;
    std::uint64_t seed = 0;
    std::string settings_manifest_hash;
    std::vector<ReplayVehicleConfig> vehicles;
    std::vector<ReplayEvent> events;
    std::vector<ReplayRunCheckpoint> checkpoints;
    std::uint64_t termination_timestamp_us = 0;
    std::string termination_reason;
};

enum class ReplayDiagnosticCode {
    None,
    Empty,
    Truncated,
    Corrupt,
    UnsupportedSchema,
    MissingManifest,
    MissingVehicleConfig,
    InvalidIdentity,
    UnknownVehicle,
    InvalidLifecycle,
    IncompatibleManifest,
    InvalidSession,
};

struct ReplayDiagnostic {
    ReplayDiagnosticCode code = ReplayDiagnosticCode::None;
    std::string message;

    bool ok() const {
        return code == ReplayDiagnosticCode::None;
    }
};

struct ReplayLoadResult {
    bool ok = false;
    ReplaySession session;
    ReplayDiagnostic diagnostic;
};

struct ReplayDivergence {
    bool diverged = false;
    std::uint64_t timestamp_us = 0;
    std::string vehicle_name;
    std::string field;
    std::string expected;
    std::string actual;
    double tolerance = 0.0;
};

class ReplayRecorder {
private:
    RecordedInputSequence sequence_;

public:
    explicit ReplayRecorder(std::string vehicle_name = {});
    void record(const FlightCommand &command);
    const std::string &vehicle_name() const;
    std::string serialized_identity() const;
    const RecordedInputSequence &sequence() const;
};

class ReplaySessionRecorder {
private:
    ReplaySession session_;
    ReplayDiagnostic diagnostic_;
    std::unordered_map<std::string, ReplayAsyncLifecycle> async_lifecycle_;
    std::unordered_map<std::string, std::string> async_methods_;
    bool finished_ = false;

    bool fail(ReplayDiagnosticCode code, std::string message);
    bool has_vehicle(const std::string &vehicle_name) const;

public:
    ReplaySessionRecorder(std::uint64_t seed, std::string settings_manifest_hash);

    bool add_vehicle(
            std::string vehicle_name,
            std::string config_manifest_hash,
            std::string config_json,
            ReplayControllerAuthority controller_authority = ReplayControllerAuthority::FlightCore);
    bool record_command(
            std::uint64_t timestamp_us,
            const std::string &vehicle_name,
            const FlightCommand &command,
            ReplayControllerAuthority controller_authority);
    bool record_mode_command(
            std::uint64_t timestamp_us,
            const std::string &vehicle_name,
            ReplayCommandMode command_mode,
            const FlightCommand &command,
            const AcroCommand &acro_command,
            ReplayControllerAuthority controller_authority);
    bool record_async_command(
            std::uint64_t timestamp_us,
            const std::string &vehicle_name,
            const std::string &command_id,
            const std::string &method,
            ReplayAsyncLifecycle lifecycle);
    bool record_simulation_operation(
            std::uint64_t timestamp_us,
            ReplaySimulationOperation operation,
            double value = 0.0);
    bool record_collision(
            std::uint64_t timestamp_us,
            const std::string &vehicle_name,
            const CollisionContact &contact,
            ReplayControllerAuthority controller_authority);
    bool record_scene_object(
            std::uint64_t timestamp_us,
            ReplaySceneObjectOperation operation,
            std::string object_name,
            std::string asset_id,
            const Vec3 &position,
            const Quat &orientation = {});
    bool record_environment(std::uint64_t timestamp_us, std::string environment_json);
    bool record_checkpoint(std::uint64_t timestamp_us, const DualAircraftState &state);
    bool finish(std::uint64_t timestamp_us, std::string reason);

    const ReplaySession &session() const;
    const ReplayDiagnostic &diagnostic() const;
    std::string serialize() const;
};

std::string serialize_replay_session(const ReplaySession &session);
ReplayLoadResult load_replay_session(
        const std::string &serialized,
        const std::string &expected_settings_manifest_hash = {});
ReplayDivergence compare_replay_sessions(
        const ReplaySession &expected,
        const ReplaySession &actual,
        double numeric_tolerance = 0.0);

struct ReplayRunResult {
    bool ok = false;
    ReplayDiagnostic diagnostic;
    DualAircraftState final_state;
    SimulationClock final_clock;
    std::uint64_t final_timestamp_us = 0;
    std::array<std::string, 2> vehicle_names;
    std::vector<ReplaySceneObjectState> scene_objects;
    std::string environment_json;
    std::vector<ReplayRunCheckpoint> checkpoints;
};

ReplayRunResult replay_session(
        const ReplaySession &session,
        const DualAircraftConfig &config,
        const std::string &expected_settings_manifest_hash,
        const std::array<std::string, 2> &expected_vehicle_config_hashes);

ReplayDivergence compare_replay_runs(
        const ReplayRunResult &expected,
        const ReplayRunResult &actual,
        double numeric_tolerance = 0.0);

std::vector<TrajectorySample> replay_angle_mode(
        const SimulationConfig &config,
        const RecordedInputSequence &inputs);
ReplayDelta compare_replay_final_state(
        const TrajectorySample &reference,
        const TrajectorySample &actual);
bool within_g06a_tolerance(const ReplayDelta &delta);

} // namespace aerosim
