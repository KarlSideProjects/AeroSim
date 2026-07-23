#pragma once

#include "aerosim_simulation.hpp"

#include <array>
#include <string>

namespace aerosim {

struct FlightCommand {
    double throttle = 0.0;
    double roll_degrees = 0.0;
    double pitch_degrees = 0.0;
    double yaw_rate_degrees_per_second = 0.0;
};

struct RateProfile {
    double rc_rate = 1.0;
    double super_rate = 0.0;
    double expo = 0.0;
};

struct AcroCommand {
    double throttle = 0.0;
    double roll_stick = 0.0;
    double pitch_stick = 0.0;
    double yaw_stick = 0.0;
    RateProfile rates;
};

struct QuadXMixerResult {
    std::array<double, 4> normalized = {0.0, 0.0, 0.0, 0.0};
    std::array<bool, 3> axis_saturated = {false, false, false};
    bool collective_saturated = false;
    bool valid = false;
};

struct PidTimingStats {
    double target_hz = 0.0;
    double p99_jitter_fraction = 0.0;
    std::uint64_t samples = 0;
};

struct FlightControlState {
    Vec3 target_angle_frd;
    Vec3 target_rate_frd;
    std::array<double, 3> rate_integral = {0.0, 0.0, 0.0};
    Vec3 previous_rate_error_frd;
    Vec3 filtered_rate_derivative_frd;
    int mode_family = 0;
    bool control_initialized = false;
    bool altitude_hold_captured = false;
    bool altitude_hold_just_captured = false;
    std::array<bool, 4> motor_saturation_latched = {false, false, false, false};
    std::array<bool, 3> pid_saturation_latched = {false, false, false};
    double motor_thrust_newtons = 0.0;
};

enum class StepStatus {
    Ok,
    InvalidCommand,
    InvalidConfig,
    InvalidState,
    InvalidControlOutput,
    ResourceLimitExceeded,
};

const char *step_status_code(StepStatus status);
StepStatus validate_angle_step_inputs(
        const RigidBodyState &state,
        const SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        const Quat &estimated_attitude);
StepStatus validate_acro_step_inputs(
        const RigidBodyState &state,
        const SimulationClock &clock,
        const SimulationConfig &config,
        const AcroCommand &command);
StepStatus validate_altitude_hold_step_inputs(
        const RigidBodyState &state,
        const SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        double measured_altitude_m,
        const Quat &estimated_attitude);

struct StepResult {
    StepStatus status = StepStatus::Ok;
    TrajectorySample sample;
};

constexpr std::int32_t kTelemetrySnapshotSchemaVersion = 2;
constexpr double kTelemetrySnapshotHz = 30.0;

struct MotorTelemetry {
    double thrust_newtons = 0.0;
    double speed_rad_s = 0.0;
    double current_a = 0.0;
    bool saturated = false;
};

struct PidAxisTelemetry {
    double output = 0.0;
    bool saturated = false;
};

struct BatteryTelemetry {
    double voltage_v = 0.0;
    double sag_v = 0.0;
    double remaining_mah = 0.0;
};

struct TelemetrySnapshot {
    std::int32_t schema_version = kTelemetrySnapshotSchemaVersion;
    std::uint64_t timestamp_us = 0;
    std::uint64_t publish_count = 0;
    double snapshot_hz = kTelemetrySnapshotHz;
    std::string vehicle_id = "primary";
    std::string world_frame = "NED";
    std::string body_frame = "FRD";
    std::string units = "SI";
    std::array<MotorTelemetry, 4> motors;
    Vec3 wind_world_mps;
    Vec3 wind_body_mps;
    double turbulence_intensity = 0.0;
    double ground_effect_gain = 0.0;
    double downwash_force_n = 0.0;
    Vec3 propwash_disturbance_rad_s2;
    Vec3 drag_body_n;
    double air_density_kg_m3 = 1.225;
    Vec3 airspeed_body_frd_mps_mean;
    Vec3 body_drag_force_body_frd_n_mean;
    Vec3 body_drag_torque_body_frd_nm_mean;
    Vec3 a3_drag_force_body_frd_n_mean;
    Vec3 a6_angular_accel_body_frd_rad_s2;
    std::string body_drag_operating_state = "disabled";
    std::string body_drag_evidence_state = "provisional";
    std::string body_drag_reason_code = "disabled";
    std::string a3_operating_state = "disabled";
    std::string a6_operating_state = "disabled";
    std::string config_hash = "unavailable";
    BatteryTelemetry battery;
    std::array<PidAxisTelemetry, 3> pid;
    std::string control_authority = "flight_controller";
    bool armed_available = true;
    bool pid_available = true;
    bool armed = false;
    std::string mode = "ANGLE";
};

double betaflight_rate_degrees_per_second(double stick, const RateProfile &profile);
double betaflight_stick_for_rate_degrees_per_second(double rate_degrees_per_second, const RateProfile &profile);
double normalize_angle_radians(double angle);
QuadXMixerResult quad_x_mix_thrust(
        const SimulationConfig &config,
        double collective_thrust_newtons,
        const Vec3 &target_torque_frd_nm);

class FlightController {
private:
    enum class ModeFamily {
        None,
        Angle,
        Acro,
    };

    bool armed_ = false;
    std::string arm_reject_code_ = "";
    int integrator_reset_count_ = 0;
    double motor_thrust_newtons_ = 0.0;
    bool altitude_hold_captured_ = false;
    double altitude_hold_target_m_ = 0.0;
    double altitude_hold_filtered_altitude_m_ = 0.0;
    double altitude_hold_vertical_speed_mps_ = 0.0;
    double altitude_hold_trim_throttle_ = 0.0;
    bool altitude_hold_just_captured_ = false;
    std::array<double, 3> rate_integral_ = {0.0, 0.0, 0.0};
    Vec3 target_angle_frd_;
    Vec3 target_rate_frd_;
    Vec3 previous_rate_error_frd_;
    Vec3 filtered_rate_derivative_frd_;
    ModeFamily mode_family_ = ModeFamily::None;
    bool control_initialized_ = false;
    std::array<bool, 4> motor_saturation_latched_ = {false, false, false, false};
    std::array<bool, 3> pid_saturation_latched_ = {false, false, false};
    PidTimingStats pid_timing_stats_;
    std::array<TelemetrySnapshot, 2> telemetry_buffers_;
    int telemetry_read_index_ = 0;
    double next_telemetry_publish_s_ = 0.0;
    std::uint64_t telemetry_publish_count_ = 0;

    void maybe_publish_telemetry(
            const TrajectorySample &sample,
            const SimulationConfig &config,
            double throttle,
            const std::array<double, 3> &pid_output,
            const std::array<bool, 3> &pid_saturated,
            const std::string &mode);
    MotorCommands control_substep(
            RigidBodyState &state,
            const SimulationConfig &config,
            double throttle,
            ModeFamily mode_family,
            const Vec3 &desired_angles_frd,
            const Vec3 &desired_rates_frd,
            const Quat &estimated_attitude,
            double dt,
            std::array<double, 3> &pid_output,
            std::array<bool, 3> &pid_saturated);
    TrajectorySample step_angle_mode_impl(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command,
            const Quat &estimated_attitude);
    TrajectorySample step_acro_mode_impl(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const AcroCommand &command);
    TrajectorySample step_altitude_hold_mode_impl(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command,
            double measured_altitude_m,
            const Quat &estimated_attitude);

public:
    bool arm(double throttle);
    void disarm();
    bool armed() const;
    const std::string &arm_reject_code() const;
    void reset_integrators();
    int integrator_reset_count() const;
    double motor_thrust_newtons() const;
    void capture_altitude_hold(double target_altitude_m);
    const PidTimingStats &pid_timing_stats() const;
    FlightControlState control_state() const;
    const TelemetrySnapshot &telemetry_snapshot() const;
    void publish_unavailable_telemetry(
            const TrajectorySample &sample,
            const SimulationConfig &config,
            const std::string &mode);
    void publish_applied_telemetry(
            const TrajectorySample &sample,
            const SimulationConfig &config,
            double throttle,
            const std::string &mode);
    void clear_propwash_telemetry();
    TrajectorySample step_angle_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command);
    TrajectorySample step_angle_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command,
            const Quat &estimated_attitude);
    StepResult try_step_angle_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command,
            const Quat &estimated_attitude);
    TrajectorySample step_acro_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const AcroCommand &command);
    StepResult try_step_acro_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const AcroCommand &command);
    TrajectorySample step_altitude_hold_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command,
            double measured_altitude_m,
            const Quat &estimated_attitude);
    StepResult try_step_altitude_hold_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command,
            double measured_altitude_m,
            const Quat &estimated_attitude);
    void reset_flight(RigidBodyState &state, SimulationClock &clock);
};

} // namespace aerosim
