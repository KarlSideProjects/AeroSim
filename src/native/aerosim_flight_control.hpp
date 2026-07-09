#pragma once

#include "aerosim_simulation.hpp"

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

struct PidTimingStats {
    double target_hz = 0.0;
    double p99_jitter_fraction = 0.0;
    std::uint64_t samples = 0;
};

double betaflight_rate_degrees_per_second(double stick, const RateProfile &profile);

class FlightController {
private:
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
    PidTimingStats pid_timing_stats_;

public:
    bool arm(double throttle);
    bool armed() const;
    const std::string &arm_reject_code() const;
    void reset_integrators();
    int integrator_reset_count() const;
    double motor_thrust_newtons() const;
    void capture_altitude_hold(double target_altitude_m);
    const PidTimingStats &pid_timing_stats() const;
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
    TrajectorySample step_acro_mode(
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
    void reset_flight(RigidBodyState &state, SimulationClock &clock);
};

} // namespace aerosim
