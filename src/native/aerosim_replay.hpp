#pragma once

#include "aerosim_flight_control.hpp"

#include <string>
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

std::vector<TrajectorySample> replay_angle_mode(
        const SimulationConfig &config,
        const RecordedInputSequence &inputs);
ReplayDelta compare_replay_final_state(
        const TrajectorySample &reference,
        const TrajectorySample &actual);
bool within_g06a_tolerance(const ReplayDelta &delta);

} // namespace aerosim
