#include "aerosim_replay.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

double square(double value) {
    return value * value;
}

std::string escape_json_string(const std::string &value) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string escaped;
    for (unsigned char character : value) {
        switch (character) {
        case '\\':
            escaped += "\\\\";
            break;
        case '"':
            escaped += "\\\"";
            break;
        case '\n':
            escaped += "\\n";
            break;
        case '\r':
            escaped += "\\r";
            break;
        case '\t':
            escaped += "\\t";
            break;
        default:
            if (character < 0x20) {
                escaped += "\\u00";
                escaped += kHex[character >> 4];
                escaped += kHex[character & 0x0f];
            } else {
                escaped += static_cast<char>(character);
            }
            break;
        }
    }
    return escaped;
}

} // namespace

ReplayRecorder::ReplayRecorder(std::string vehicle_name) {
    sequence_.vehicle_name = std::move(vehicle_name);
}

void ReplayRecorder::record(const FlightCommand &command) {
    sequence_.frames.push_back(command);
}

const std::string &ReplayRecorder::vehicle_name() const {
    return sequence_.vehicle_name;
}

std::string ReplayRecorder::serialized_identity() const {
    return "{\"vehicle_name\":\"" + escape_json_string(sequence_.vehicle_name) +
            "\",\"frame_count\":" + std::to_string(sequence_.frames.size()) + "}";
}

const RecordedInputSequence &ReplayRecorder::sequence() const {
    return sequence_;
}

std::vector<TrajectorySample> replay_angle_mode(
        const SimulationConfig &config,
        const RecordedInputSequence &inputs) {
    std::vector<TrajectorySample> samples;
    samples.reserve(inputs.frames.size());

    RigidBodyState state = config.initial_state;
    SimulationClock clock;
    FlightController controller;
    controller.arm(0.0);

    for (const FlightCommand &command : inputs.frames) {
        samples.push_back(controller.step_angle_mode(state, clock, config, command));
    }

    return samples;
}

ReplayDelta compare_replay_final_state(
        const TrajectorySample &reference,
        const TrajectorySample &actual) {
    const double reference_norm = quat_norm(reference.state.orientation);
    const double actual_norm = quat_norm(actual.state.orientation);
    double orientation_degrees = 180.0;
    if (std::isfinite(reference_norm) && std::isfinite(actual_norm) && reference_norm > 0.0 && actual_norm > 0.0) {
        const Quat &a = reference.state.orientation;
        const Quat &b = actual.state.orientation;
        const double dot = std::abs(
                (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w) /
                (reference_norm * actual_norm));
        orientation_degrees = 2.0 * std::acos(std::clamp(dot, 0.0, 1.0)) * 180.0 / kPi;
    }

    const Vec3 position_delta{
            actual.state.position.x - reference.state.position.x,
            actual.state.position.y - reference.state.position.y,
            actual.state.position.z - reference.state.position.z,
    };
    return {
            orientation_degrees,
            std::sqrt(square(position_delta.x) + square(position_delta.y) + square(position_delta.z)),
    };
}

bool within_g06a_tolerance(const ReplayDelta &delta) {
    return std::isfinite(delta.orientation_degrees) &&
            std::isfinite(delta.position_meters) &&
            delta.orientation_degrees <= 0.5 &&
            delta.position_meters <= 0.05;
}

} // namespace aerosim
