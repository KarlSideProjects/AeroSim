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

class FlightController {
private:
    bool armed_ = false;
    std::string arm_reject_code_ = "";
    int integrator_reset_count_ = 0;

public:
    bool arm(double throttle);
    bool armed() const;
    const std::string &arm_reject_code() const;
    void reset_integrators();
    int integrator_reset_count() const;
    TrajectorySample step_angle_mode(
            RigidBodyState &state,
            SimulationClock &clock,
            const SimulationConfig &config,
            const FlightCommand &command);
    void reset_flight(RigidBodyState &state, SimulationClock &clock);
};

} // namespace aerosim
