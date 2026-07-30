#pragma once

#include "aerosim_collision.hpp"

#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <vector>

namespace aerosim {

class WindField;

struct RecordedInputSequence {
    std::string vehicle_name;
    std::vector<FlightCommand> frames;
};

struct ReplayDelta {
    double orientation_degrees = 0.0;
    double position_meters = 0.0;
};

constexpr std::int32_t kLegacyReplaySchemaVersion = 4;
constexpr std::int32_t kCompleteReplaySchemaVersion = 5;
constexpr std::size_t kMaxBatchTrajectoryFrames = 1'000'000;
constexpr std::size_t kNoFailedReplayFrame = std::numeric_limits<std::size_t>::max();

enum class ReplayControllerAuthority {
    FlightCore,
    Jolt,
    Px4External,
};

enum class ReplayCommandMode {
    Angle,
    Acro,
    AltitudeHold,
    Actuator,
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
    Tuning,
    QuickAdjustBinding,
    Marker,
};

struct ReplayEventIdentity {
    std::uint64_t timestamp_us = 0;
    std::uint64_t physics_tick = 0;
    std::uint64_t event_order = 0;
    ReplayEventType type = ReplayEventType::Command;
};

struct ReplayEvent {
    std::uint64_t timestamp_us = 0;
    std::uint64_t physics_tick = 0;
    std::uint64_t event_order = 0;
    bool has_authoritative_order = false;
    ReplayEventType type = ReplayEventType::Command;
    std::string vehicle_name;
    ReplayControllerAuthority controller_authority = ReplayControllerAuthority::FlightCore;
    ReplayCommandMode command_mode = ReplayCommandMode::Angle;
    FlightCommand command;
    AcroCommand acro_command;
    std::array<double, 4> actuator_commands = {0.0, 0.0, 0.0, 0.0};
    double measured_altitude_m = 0.0;
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
    std::uint64_t tuning_request_seq = 0;
    std::uint64_t tuning_commit_id = 0;
    std::string tuning_parameter;
    double tuning_requested_value = 0.0;
    double tuning_committed_value = 0.0;
    bool tuning_clamped = false;
    std::string tuning_source = "panel";
    std::int32_t tuning_quick_adjust_slot = -1;
    std::string quick_adjust_profile_json;
    std::string marker_label;
    std::string marker_note;
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
    std::array<FlightControlState, 2> controllers;
    std::array<SimulationClock, 2> clocks;
    std::array<TrajectorySample, 2> first_response_substeps;
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
    std::string environment_json_;
    std::array<ReplayCollision, 2> checkpoint_collisions_;
    std::vector<ReplaySceneObjectState> checkpoint_scene_objects_;
    std::uint64_t physics_tick_ = 0;
    std::uint64_t next_event_order_ = 0;
    bool finished_ = false;
    bool append_failed_ = false;

    bool fail(ReplayDiagnosticCode code, std::string message);
    bool has_vehicle(const std::string &vehicle_name) const;
    bool append_event(ReplayEvent event, ReplayEventIdentity *identity = nullptr);

#ifdef AEROSIM_REPLAY_TESTING
    friend struct ReplaySessionRecorderTestAccess;
#endif

public:
    ReplaySessionRecorder(std::uint64_t seed, std::string settings_manifest_hash);

    bool set_physics_tick(std::uint64_t physics_tick);

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
            ReplayControllerAuthority controller_authority,
            double measured_altitude_m = 0.0);
    bool record_actuator_command(
            std::uint64_t timestamp_us,
            const std::string &vehicle_name,
            const MotorCommands &commands,
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
    bool record_environment(
            std::uint64_t timestamp_us,
            std::string environment_json,
            ReplayEventIdentity *identity = nullptr);
    bool record_quick_adjust_binding(
            std::uint64_t timestamp_us,
            std::string profile_json);
    bool record_tuning(
            std::uint64_t timestamp_us,
            const std::string &vehicle_name,
            std::uint64_t request_seq,
            std::uint64_t commit_id,
            const std::string &parameter,
            double requested_value,
            double committed_value,
            bool clamped,
            const std::string &source = "panel",
            std::int32_t quick_adjust_slot = -1);
    bool record_marker(
            std::uint64_t timestamp_us,
            std::string label,
            std::string note = {});
    bool record_checkpoint(std::uint64_t timestamp_us, const DualAircraftState &state);
    bool record_checkpoint(std::uint64_t timestamp_us, ReplayRunCheckpoint checkpoint);
    bool finish(std::uint64_t timestamp_us, std::string reason);

    const ReplaySession &session() const;
    const ReplayDiagnostic &diagnostic() const;
    std::string serialize() const;
};

std::string serialize_replay_session(const ReplaySession &session);
ReplayLoadResult load_replay_session(
        const std::string &serialized,
        const std::string &expected_settings_manifest_hash = {});
std::string serialize_replay_session_jsonl(const ReplaySession &session);
std::string derive_replay_session_jsonl(
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

struct ReplayBatchResult {
    StepStatus status = StepStatus::Ok;
    std::vector<TrajectorySample> rows;
    std::size_t failed_frame = kNoFailedReplayFrame;
};

ReplayRunResult replay_session(
        const ReplaySession &session,
        const DualAircraftConfig &config,
        const std::string &expected_settings_manifest_hash,
        const std::array<std::string, 2> &expected_vehicle_config_hashes,
        bool require_complete_vehicle_manifest = false);

ReplayDivergence compare_replay_runs(
        const ReplayRunResult &expected,
        const ReplayRunResult &actual,
        double numeric_tolerance = 0.0);

std::vector<TrajectorySample> replay_angle_mode(
        const SimulationConfig &config,
        const RecordedInputSequence &inputs);
ReplayBatchResult replay_angle_mode_batch(
        const SimulationConfig &config,
        const RecordedInputSequence &inputs,
        const WindField *wind_field = nullptr);
ReplayBatchResult replay_angle_mode_seconds_batch(
        const SimulationConfig &config,
        const FlightCommand &command,
        double seconds);
ReplayBatchResult replay_angle_mode_seconds_batch(
        const SimulationConfig &config,
        const FlightCommand &command,
        double seconds,
        const WindField &wind_field);
ReplayDelta compare_replay_final_state(
        const TrajectorySample &reference,
        const TrajectorySample &actual);
bool within_g06a_tolerance(const ReplayDelta &delta);

} // namespace aerosim
