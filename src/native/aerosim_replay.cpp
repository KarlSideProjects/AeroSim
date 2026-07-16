#include "aerosim_replay.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <limits>
#include <map>
#include <sstream>
#include <utility>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

double square(double value) {
    return value * value;
}

std::string async_lifecycle_key(const std::string &vehicle_name, const std::string &command_id) {
    return vehicle_name + '\n' + command_id;
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

namespace {

struct JsonValue {
    enum class Type {
        Null,
        Boolean,
        Number,
        String,
        Array,
        Object,
    };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0.0;
    std::string number_text;
    std::string string;
    std::vector<JsonValue> array;
    std::vector<std::pair<std::string, JsonValue>> object;
};

class JsonParser {
private:
    const std::string &input_;
    std::size_t position_ = 0;
    bool truncated_ = false;
    std::string error_;

    void skip_space() {
        while (position_ < input_.size() && std::isspace(static_cast<unsigned char>(input_[position_])) != 0) {
            ++position_;
        }
    }

    bool expect(char expected) {
        skip_space();
        if (position_ >= input_.size()) {
            truncated_ = true;
            error_ = "unexpected end of replay";
            return false;
        }
        if (input_[position_] != expected) {
            error_ = "invalid replay JSON";
            return false;
        }
        ++position_;
        return true;
    }

    bool parse_string_value(std::string &value) {
        skip_space();
        if (position_ >= input_.size()) {
            truncated_ = true;
            error_ = "truncated replay string";
            return false;
        }
        if (input_[position_++] != '"') {
            error_ = "replay string must start with a quote";
            return false;
        }
        while (position_ < input_.size()) {
            const unsigned char character = static_cast<unsigned char>(input_[position_++]);
            if (character == '"') {
                return true;
            }
            if (character < 0x20) {
                error_ = "control character in replay string";
                return false;
            }
            if (character != '\\') {
                value += static_cast<char>(character);
                continue;
            }
            if (position_ >= input_.size()) {
                truncated_ = true;
                error_ = "truncated replay escape";
                return false;
            }
            const char escape = input_[position_++];
            switch (escape) {
            case '"':
            case '\\':
            case '/':
                value += escape;
                break;
            case 'b':
                value += '\b';
                break;
            case 'f':
                value += '\f';
                break;
            case 'n':
                value += '\n';
                break;
            case 'r':
                value += '\r';
                break;
            case 't':
                value += '\t';
                break;
            case 'u': {
                if (position_ + 4 > input_.size()) {
                    truncated_ = true;
                    error_ = "truncated replay unicode escape";
                    return false;
                }
                unsigned int codepoint = 0;
                for (int index = 0; index < 4; ++index) {
                    const char hex = input_[position_++];
                    codepoint <<= 4;
                    if (hex >= '0' && hex <= '9') {
                        codepoint += static_cast<unsigned int>(hex - '0');
                    } else if (hex >= 'a' && hex <= 'f') {
                        codepoint += static_cast<unsigned int>(hex - 'a' + 10);
                    } else if (hex >= 'A' && hex <= 'F') {
                        codepoint += static_cast<unsigned int>(hex - 'A' + 10);
                    } else {
                        error_ = "invalid replay unicode escape";
                        return false;
                    }
                }
                if (codepoint <= 0x7f) {
                    value += static_cast<char>(codepoint);
                } else {
                    error_ = "non-ASCII replay unicode is unsupported";
                    return false;
                }
                break;
            }
            default:
                error_ = "invalid replay escape";
                return false;
            }
        }
        truncated_ = true;
        error_ = "truncated replay string";
        return false;
    }

    bool parse_number_value(double &value, std::string &number_text) {
        skip_space();
        const std::size_t start_position = position_;
        if (position_ < input_.size() && input_[position_] == '-') {
            ++position_;
        }
        if (position_ >= input_.size()) {
            truncated_ = true;
            error_ = "truncated replay number";
            return false;
        }
        if (input_[position_] == '0') {
            ++position_;
            if (position_ < input_.size() && std::isdigit(static_cast<unsigned char>(input_[position_])) != 0) {
                error_ = "invalid replay number";
                return false;
            }
        } else if (input_[position_] >= '1' && input_[position_] <= '9') {
            while (position_ < input_.size() && std::isdigit(static_cast<unsigned char>(input_[position_])) != 0) {
                ++position_;
            }
        } else {
            error_ = "invalid replay number";
            return false;
        }
        if (position_ < input_.size() && input_[position_] == '.') {
            ++position_;
            const std::size_t fraction_start = position_;
            while (position_ < input_.size() && std::isdigit(static_cast<unsigned char>(input_[position_])) != 0) {
                ++position_;
            }
            if (position_ == fraction_start) {
                error_ = "invalid replay number";
                return false;
            }
        }
        if (position_ < input_.size() && (input_[position_] == 'e' || input_[position_] == 'E')) {
            ++position_;
            if (position_ < input_.size() && (input_[position_] == '+' || input_[position_] == '-')) {
                ++position_;
            }
            const std::size_t exponent_start = position_;
            while (position_ < input_.size() && std::isdigit(static_cast<unsigned char>(input_[position_])) != 0) {
                ++position_;
            }
            if (position_ == exponent_start) {
                error_ = "invalid replay number";
                return false;
            }
        }
        number_text = input_.substr(start_position, position_ - start_position);
        const char *start = number_text.c_str();
        char *end = nullptr;
        value = std::strtod(start, &end);
        if (end == start || *end != '\0') {
            error_ = "invalid replay number";
            return false;
        }
        if (!std::isfinite(value)) {
            error_ = "replay number must be finite";
            return false;
        }
        return true;
    }

    bool parse_value(JsonValue &value) {
        skip_space();
        if (position_ >= input_.size()) {
            truncated_ = true;
            error_ = "truncated replay value";
            return false;
        }
        switch (input_[position_]) {
        case '{':
            return parse_object(value);
        case '[':
            return parse_array(value);
        case '"':
            value.type = JsonValue::Type::String;
            return parse_string_value(value.string);
        case 't':
            if (input_.compare(position_, 4, "true") != 0) {
                error_ = "invalid replay boolean";
                return false;
            }
            position_ += 4;
            value.type = JsonValue::Type::Boolean;
            value.boolean = true;
            return true;
        case 'f':
            if (input_.compare(position_, 5, "false") != 0) {
                error_ = "invalid replay boolean";
                return false;
            }
            position_ += 5;
            value.type = JsonValue::Type::Boolean;
            value.boolean = false;
            return true;
        case 'n':
            if (input_.compare(position_, 4, "null") != 0) {
                error_ = "invalid replay value";
                return false;
            }
            position_ += 4;
            value.type = JsonValue::Type::Null;
            return true;
        default:
            value.type = JsonValue::Type::Number;
            return parse_number_value(value.number, value.number_text);
        }
    }

    bool parse_object(JsonValue &value) {
        value.type = JsonValue::Type::Object;
        ++position_;
        skip_space();
        if (position_ >= input_.size()) {
            truncated_ = true;
            error_ = "truncated replay object";
            return false;
        }
        if (input_[position_] == '}') {
            ++position_;
            return true;
        }
        while (true) {
            std::string key;
            if (!parse_string_value(key) || !expect(':')) {
                return false;
            }
            JsonValue child;
            if (!parse_value(child)) {
                return false;
            }
            value.object.emplace_back(std::move(key), std::move(child));
            skip_space();
            if (position_ >= input_.size()) {
                truncated_ = true;
                error_ = "truncated replay object";
                return false;
            }
            if (input_[position_] == '}') {
                ++position_;
                return true;
            }
            if (input_[position_] != ',') {
                error_ = "invalid replay object separator";
                return false;
            }
            ++position_;
        }
    }

    bool parse_array(JsonValue &value) {
        value.type = JsonValue::Type::Array;
        ++position_;
        skip_space();
        if (position_ >= input_.size()) {
            truncated_ = true;
            error_ = "truncated replay array";
            return false;
        }
        if (input_[position_] == ']') {
            ++position_;
            return true;
        }
        while (true) {
            JsonValue child;
            if (!parse_value(child)) {
                return false;
            }
            value.array.push_back(std::move(child));
            skip_space();
            if (position_ >= input_.size()) {
                truncated_ = true;
                error_ = "truncated replay array";
                return false;
            }
            if (input_[position_] == ']') {
                ++position_;
                return true;
            }
            if (input_[position_] != ',') {
                error_ = "invalid replay array separator";
                return false;
            }
            ++position_;
        }
    }

public:
    explicit JsonParser(const std::string &input) : input_(input) {}

    bool parse(JsonValue &value) {
        if (!parse_value(value)) {
            return false;
        }
        skip_space();
        if (position_ != input_.size()) {
            error_ = "trailing data in replay";
            return false;
        }
        return true;
    }

    bool truncated() const {
        return truncated_;
    }

    const std::string &error() const {
        return error_;
    }
};

const JsonValue *field(const JsonValue &value, const char *key) {
    if (value.type != JsonValue::Type::Object) {
        return nullptr;
    }
    for (const auto &entry : value.object) {
        if (entry.first == key) {
            return &entry.second;
        }
    }
    return nullptr;
}

bool string_value(const JsonValue &value, std::string &result) {
    if (value.type != JsonValue::Type::String) {
        return false;
    }
    result = value.string;
    return true;
}

bool number_value(const JsonValue &value, double &result) {
    if (value.type != JsonValue::Type::Number || !std::isfinite(value.number)) {
        return false;
    }
    result = value.number;
    return true;
}

bool bool_value(const JsonValue &value, bool &result) {
    if (value.type != JsonValue::Type::Boolean) {
        return false;
    }
    result = value.boolean;
    return true;
}

std::string compact_json(const JsonValue &value);

std::string compact_number(double value) {
    std::ostringstream output;
    output << std::setprecision(17) << value;
    return output.str();
}

std::string compact_json(const JsonValue &value) {
    switch (value.type) {
    case JsonValue::Type::Null:
        return "null";
    case JsonValue::Type::Boolean:
        return value.boolean ? "true" : "false";
    case JsonValue::Type::Number:
        return value.number_text.empty() ? compact_number(value.number) : value.number_text;
    case JsonValue::Type::String:
        return "\"" + escape_json_string(value.string) + "\"";
    case JsonValue::Type::Array: {
        std::string result = "[";
        for (std::size_t index = 0; index < value.array.size(); ++index) {
            if (index != 0) {
                result += ',';
            }
            result += compact_json(value.array[index]);
        }
        return result + ']';
    }
    case JsonValue::Type::Object: {
        std::string result = "{";
        for (std::size_t index = 0; index < value.object.size(); ++index) {
            if (index != 0) {
                result += ',';
            }
            result += "\"" + escape_json_string(value.object[index].first) + "\":" + compact_json(value.object[index].second);
        }
        return result + '}';
    }
    }
    return "null";
}

bool valid_identity(const std::string &value) {
    if (value.empty() || !std::isalpha(static_cast<unsigned char>(value.front()))) {
        return false;
    }
    for (char character : value) {
        if (!std::isalnum(static_cast<unsigned char>(character)) && character != '_' && character != '-') {
            return false;
        }
    }
    return value.size() <= 64;
}

bool finite_command(const FlightCommand &command) {
    return std::isfinite(command.throttle) && std::isfinite(command.roll_degrees) &&
            std::isfinite(command.pitch_degrees) && std::isfinite(command.yaw_rate_degrees_per_second);
}

bool finite_vec(const Vec3 &value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

bool finite_quat(const Quat &value) {
    return finite_vec({value.x, value.y, value.z}) && std::isfinite(value.w);
}

std::string vec_json(const Vec3 &value) {
    return "[" + compact_number(value.x) + "," + compact_number(value.y) + "," + compact_number(value.z) + "]";
}

std::string quat_json(const Quat &value) {
    return "[" + compact_number(value.x) + "," + compact_number(value.y) + "," + compact_number(value.z) + "," + compact_number(value.w) + "]";
}

bool parse_vec(const JsonValue &value, Vec3 &result) {
    if (value.type != JsonValue::Type::Array || value.array.size() != 3) {
        return false;
    }
    double values[3] = {};
    for (std::size_t index = 0; index < 3; ++index) {
        if (!number_value(value.array[index], values[index])) {
            return false;
        }
    }
    result = {values[0], values[1], values[2]};
    return true;
}

bool parse_quat(const JsonValue &value, Quat &result) {
    if (value.type != JsonValue::Type::Array || value.array.size() != 4) {
        return false;
    }
    double values[4] = {};
    for (std::size_t index = 0; index < 4; ++index) {
        if (!number_value(value.array[index], values[index])) {
            return false;
        }
    }
    result = {values[0], values[1], values[2], values[3]};
    return true;
}

const char *authority_name(ReplayControllerAuthority value) {
    switch (value) {
    case ReplayControllerAuthority::FlightCore:
        return "flight_core";
    case ReplayControllerAuthority::Jolt:
        return "jolt";
    case ReplayControllerAuthority::Px4External:
        return "px4_external";
    }
    return "";
}

bool parse_authority(const std::string &value, ReplayControllerAuthority &result) {
    if (value == "flight_core") {
        result = ReplayControllerAuthority::FlightCore;
    } else if (value == "jolt") {
        result = ReplayControllerAuthority::Jolt;
    } else if (value == "px4_external") {
        result = ReplayControllerAuthority::Px4External;
    } else {
        return false;
    }
    return true;
}

const char *lifecycle_name(ReplayAsyncLifecycle value) {
    switch (value) {
    case ReplayAsyncLifecycle::Submitted:
        return "submitted";
    case ReplayAsyncLifecycle::Accepted:
        return "accepted";
    case ReplayAsyncLifecycle::Completed:
        return "completed";
    case ReplayAsyncLifecycle::Cancelled:
        return "cancelled";
    case ReplayAsyncLifecycle::TimedOut:
        return "timed_out";
    }
    return "";
}

bool parse_lifecycle(const std::string &value, ReplayAsyncLifecycle &result) {
    const std::string names[] = {"submitted", "accepted", "completed", "cancelled", "timed_out"};
    for (int index = 0; index < 5; ++index) {
        if (value == names[index]) {
            result = static_cast<ReplayAsyncLifecycle>(index);
            return true;
        }
    }
    return false;
}

const char *simulation_operation_name(ReplaySimulationOperation value) {
    switch (value) {
    case ReplaySimulationOperation::Pause:
        return "pause";
    case ReplaySimulationOperation::Resume:
        return "resume";
    case ReplaySimulationOperation::StepFrames:
        return "step_frames";
    case ReplaySimulationOperation::StepSeconds:
        return "step_seconds";
    case ReplaySimulationOperation::Reset:
        return "reset";
    case ReplaySimulationOperation::Respawn:
        return "respawn";
    }
    return "";
}

bool parse_simulation_operation(const std::string &value, ReplaySimulationOperation &result) {
    const std::string names[] = {"pause", "resume", "step_frames", "step_seconds", "reset", "respawn"};
    for (int index = 0; index < 6; ++index) {
        if (value == names[index]) {
            result = static_cast<ReplaySimulationOperation>(index);
            return true;
        }
    }
    return false;
}

const char *object_operation_name(ReplaySceneObjectOperation value) {
    switch (value) {
    case ReplaySceneObjectOperation::Spawn:
        return "spawn";
    case ReplaySceneObjectOperation::Move:
        return "move";
    case ReplaySceneObjectOperation::Destroy:
        return "destroy";
    case ReplaySceneObjectOperation::Reset:
        return "reset";
    }
    return "";
}

bool parse_object_operation(const std::string &value, ReplaySceneObjectOperation &result) {
    const std::string names[] = {"spawn", "move", "destroy", "reset"};
    for (int index = 0; index < 4; ++index) {
        if (value == names[index]) {
            result = static_cast<ReplaySceneObjectOperation>(index);
            return true;
        }
    }
    return false;
}

const char *event_type_name(ReplayEventType value) {
    switch (value) {
    case ReplayEventType::Command:
        return "command";
    case ReplayEventType::AsyncCommand:
        return "async_command";
    case ReplayEventType::SimulationTime:
        return "simulation_time";
    case ReplayEventType::Collision:
        return "collision";
    case ReplayEventType::SceneObject:
        return "scene_object";
    case ReplayEventType::Environment:
        return "environment";
    }
    return "";
}

bool parse_event_type(const std::string &value, ReplayEventType &result) {
    const std::string names[] = {"command", "async_command", "simulation_time", "collision", "scene_object", "environment"};
    for (int index = 0; index < 6; ++index) {
        if (value == names[index]) {
            result = static_cast<ReplayEventType>(index);
            return true;
        }
    }
    return false;
}

bool integer_value(const JsonValue &value, std::uint64_t &result) {
    if (value.type != JsonValue::Type::Number || value.number_text.find_first_of(".eE-") != std::string::npos ||
            value.number_text.empty()) {
        return false;
    }
    const auto parsed = std::from_chars(value.number_text.data(), value.number_text.data() + value.number_text.size(), result);
    return parsed.ec == std::errc{} && parsed.ptr == value.number_text.data() + value.number_text.size();
}

bool signed_integer_value(const JsonValue &value, std::int64_t &result) {
    if (value.type != JsonValue::Type::Number || value.number_text.find_first_of(".eE") != std::string::npos ||
            value.number_text.empty()) {
        return false;
    }
    const auto parsed = std::from_chars(value.number_text.data(), value.number_text.data() + value.number_text.size(), result);
    return parsed.ec == std::errc{} && parsed.ptr == value.number_text.data() + value.number_text.size();
}

ReplayDiagnostic invalid(ReplayDiagnosticCode code, const std::string &message) {
    return {code, message};
}

ReplayDiagnostic validate_session(const ReplaySession &session, bool require_termination) {
    if (session.schema_version != kCompleteReplaySchemaVersion) {
        return invalid(ReplayDiagnosticCode::UnsupportedSchema, "unsupported replay schema version");
    }
    if (session.settings_manifest_hash.empty()) {
        return invalid(ReplayDiagnosticCode::MissingManifest, "replay settings manifest hash is required");
    }
    if (session.vehicles.size() != 2) {
        return invalid(ReplayDiagnosticCode::InvalidSession, "complete replay requires exactly two vehicles");
    }
    std::vector<std::string> names;
    for (const ReplayVehicleConfig &vehicle : session.vehicles) {
        if (!valid_identity(vehicle.name)) {
            return invalid(ReplayDiagnosticCode::InvalidIdentity, "invalid replay vehicle identity: " + vehicle.name);
        }
        if (std::find(names.begin(), names.end(), vehicle.name) != names.end()) {
            return invalid(ReplayDiagnosticCode::InvalidIdentity, "duplicate replay vehicle identity: " + vehicle.name);
        }
        if (vehicle.config_manifest_hash.empty() || vehicle.config_json.empty()) {
            return invalid(ReplayDiagnosticCode::MissingVehicleConfig, "vehicle config is required: " + vehicle.name);
        }
        names.push_back(vehicle.name);
    }
    if (require_termination && session.termination_reason.empty()) {
        return invalid(ReplayDiagnosticCode::InvalidSession, "replay termination is required");
    }
    std::uint64_t previous_timestamp_us = 0;
    bool has_previous_timestamp = false;
    for (const ReplayEvent &event : session.events) {
        if (has_previous_timestamp && event.timestamp_us < previous_timestamp_us) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay events must be monotonic");
        }
        previous_timestamp_us = event.timestamp_us;
        has_previous_timestamp = true;
        if (require_termination && event.timestamp_us > session.termination_timestamp_us) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay event occurs after termination");
        }
        const bool requires_vehicle = event.type == ReplayEventType::Command ||
                event.type == ReplayEventType::AsyncCommand || event.type == ReplayEventType::Collision;
        if (requires_vehicle && event.vehicle_name.empty()) {
            return invalid(ReplayDiagnosticCode::InvalidIdentity, "vehicle identity is required for replay event");
        }
        if (!event.vehicle_name.empty() && std::find(names.begin(), names.end(), event.vehicle_name) == names.end()) {
            return invalid(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + event.vehicle_name);
        }
        if (event.type == ReplayEventType::Command && !finite_command(event.command)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay command contains a non-finite value");
        }
    }
    std::unordered_map<std::string, ReplayAsyncLifecycle> lifecycle;
    std::unordered_map<std::string, std::string> methods;
    for (const ReplayEvent &event : session.events) {
        if (event.type != ReplayEventType::AsyncCommand) {
            continue;
        }
        const std::string key = async_lifecycle_key(event.vehicle_name, event.command_id);
        const auto current = lifecycle.find(key);
        const auto method = methods.find(key);
        if (method != methods.end() && method->second != event.command_method) {
            return invalid(ReplayDiagnosticCode::InvalidLifecycle, "async replay method changed for command: " + event.command_id);
        }
        bool allowed = false;
        if (event.command_lifecycle == ReplayAsyncLifecycle::Submitted) {
            allowed = current == lifecycle.end();
        } else if (current != lifecycle.end() && current->second == ReplayAsyncLifecycle::Submitted) {
            allowed = event.command_lifecycle == ReplayAsyncLifecycle::Accepted;
        } else if (current != lifecycle.end() && current->second == ReplayAsyncLifecycle::Accepted) {
            allowed = event.command_lifecycle == ReplayAsyncLifecycle::Completed ||
                    event.command_lifecycle == ReplayAsyncLifecycle::Cancelled ||
                    event.command_lifecycle == ReplayAsyncLifecycle::TimedOut;
        }
        if (!allowed) {
            return invalid(ReplayDiagnosticCode::InvalidLifecycle, "invalid async replay lifecycle for command: " + event.command_id);
        }
        lifecycle[key] = event.command_lifecycle;
        methods[key] = event.command_method;
    }
    if (require_termination) {
        for (const auto &entry : lifecycle) {
            if (entry.second == ReplayAsyncLifecycle::Submitted || entry.second == ReplayAsyncLifecycle::Accepted) {
                return invalid(ReplayDiagnosticCode::InvalidLifecycle, "async replay command did not reach a terminal lifecycle");
            }
        }
    }
    return {};
}

std::string command_json(const FlightCommand &command) {
    return "{\"throttle\":" + compact_number(command.throttle) +
            ",\"roll_degrees\":" + compact_number(command.roll_degrees) +
            ",\"pitch_degrees\":" + compact_number(command.pitch_degrees) +
            ",\"yaw_rate_degrees_per_second\":" + compact_number(command.yaw_rate_degrees_per_second) + "}";
}

std::string event_json(const ReplayEvent &event) {
    std::string result = "{\"timestamp_us\":" + std::to_string(event.timestamp_us) +
            ",\"type\":\"" + event_type_name(event.type) + "\"";
    if (!event.vehicle_name.empty()) {
        result += ",\"vehicle\":\"" + escape_json_string(event.vehicle_name) + "\"";
    }
    switch (event.type) {
    case ReplayEventType::Command:
        result += ",\"authority\":\"" + std::string(authority_name(event.controller_authority)) +
                "\",\"command\":" + command_json(event.command);
        break;
    case ReplayEventType::AsyncCommand:
        result += ",\"command_id\":\"" + escape_json_string(event.command_id) +
                "\",\"method\":\"" + escape_json_string(event.command_method) +
                "\",\"lifecycle\":\"" + lifecycle_name(event.command_lifecycle) + "\"";
        break;
    case ReplayEventType::SimulationTime:
        result += ",\"operation\":\"" + std::string(simulation_operation_name(event.simulation_operation)) +
                "\",\"value\":" + std::to_string(event.simulation_value);
        break;
    case ReplayEventType::Collision:
        result += ",\"authority\":\"" + std::string(authority_name(event.collision.authority)) +
                "\",\"touching\":" + std::string(event.collision.contact.touching ? "true" : "false") +
                ",\"normal\":" + vec_json(event.collision.contact.normal) +
                ",\"impulse\":" + vec_json(event.collision.contact.impulse) +
                ",\"restitution\":" + compact_number(event.collision.contact.restitution) +
                ",\"resolved_velocity\":" + vec_json(event.collision.contact.resolved_velocity) +
                ",\"resolved_angular_velocity\":" + vec_json(event.collision.contact.resolved_angular_velocity) +
                ",\"max_kinetic_energy_joules\":" + compact_number(event.collision.contact.max_kinetic_energy_joules) +
                ",\"has_resolved_state\":" + std::string(event.collision.contact.has_resolved_state ? "true" : "false");
        break;
    case ReplayEventType::SceneObject:
        result += ",\"operation\":\"" + std::string(object_operation_name(event.object_operation)) +
                "\",\"name\":\"" + escape_json_string(event.object_name) +
                "\",\"asset_id\":\"" + escape_json_string(event.object_asset_id) +
                "\",\"position\":" + vec_json(event.object_position) +
                ",\"orientation\":" + quat_json(event.object_orientation);
        break;
    case ReplayEventType::Environment:
        result += ",\"state\":" + event.environment_json;
        break;
    }
    return result + '}';
}

bool parse_command(const JsonValue &value, FlightCommand &command) {
    const JsonValue *throttle = field(value, "throttle");
    const JsonValue *roll = field(value, "roll_degrees");
    const JsonValue *pitch = field(value, "pitch_degrees");
    const JsonValue *yaw = field(value, "yaw_rate_degrees_per_second");
    return throttle != nullptr && roll != nullptr && pitch != nullptr && yaw != nullptr &&
            number_value(*throttle, command.throttle) && number_value(*roll, command.roll_degrees) &&
            number_value(*pitch, command.pitch_degrees) && number_value(*yaw, command.yaw_rate_degrees_per_second);
}

bool parse_event(const JsonValue &value, ReplayEvent &event) {
    const JsonValue *timestamp = field(value, "timestamp_us");
    const JsonValue *type = field(value, "type");
    std::string type_name;
    if (timestamp == nullptr || type == nullptr || !integer_value(*timestamp, event.timestamp_us) ||
            !string_value(*type, type_name) || !parse_event_type(type_name, event.type)) {
        return false;
    }
    const JsonValue *vehicle = field(value, "vehicle");
    if (vehicle != nullptr && !string_value(*vehicle, event.vehicle_name)) {
        return false;
    }
    switch (event.type) {
    case ReplayEventType::Command: {
        std::string authority;
        const JsonValue *authority_value = field(value, "authority");
        const JsonValue *command = field(value, "command");
        return authority_value != nullptr && command != nullptr && string_value(*authority_value, authority) &&
                parse_authority(authority, event.controller_authority) && parse_command(*command, event.command);
    }
    case ReplayEventType::AsyncCommand: {
        std::string lifecycle;
        const JsonValue *id = field(value, "command_id");
        const JsonValue *method = field(value, "method");
        const JsonValue *lifecycle_value = field(value, "lifecycle");
        return id != nullptr && method != nullptr && lifecycle_value != nullptr &&
                string_value(*id, event.command_id) && string_value(*method, event.command_method) &&
                string_value(*lifecycle_value, lifecycle) && parse_lifecycle(lifecycle, event.command_lifecycle);
    }
    case ReplayEventType::SimulationTime: {
        std::string operation;
        const JsonValue *operation_value = field(value, "operation");
        const JsonValue *simulation_value = field(value, "value");
        return operation_value != nullptr && simulation_value != nullptr && string_value(*operation_value, operation) &&
                parse_simulation_operation(operation, event.simulation_operation) &&
                signed_integer_value(*simulation_value, event.simulation_value);
    }
    case ReplayEventType::Collision: {
        std::string authority;
        bool touching = false;
        bool has_resolved_state = false;
        const JsonValue *authority_value = field(value, "authority");
        const JsonValue *touching_value = field(value, "touching");
        const JsonValue *normal = field(value, "normal");
        const JsonValue *impulse = field(value, "impulse");
        const JsonValue *restitution = field(value, "restitution");
        const JsonValue *resolved_velocity = field(value, "resolved_velocity");
        const JsonValue *resolved_angular_velocity = field(value, "resolved_angular_velocity");
        const JsonValue *max_energy = field(value, "max_kinetic_energy_joules");
        const JsonValue *has_resolved = field(value, "has_resolved_state");
        return authority_value != nullptr && touching_value != nullptr && normal != nullptr && impulse != nullptr &&
                restitution != nullptr && resolved_velocity != nullptr && resolved_angular_velocity != nullptr &&
                max_energy != nullptr && has_resolved != nullptr && string_value(*authority_value, authority) &&
                parse_authority(authority, event.collision.authority) && bool_value(*touching_value, touching) &&
                parse_vec(*normal, event.collision.contact.normal) && parse_vec(*impulse, event.collision.contact.impulse) &&
                number_value(*restitution, event.collision.contact.restitution) &&
                parse_vec(*resolved_velocity, event.collision.contact.resolved_velocity) &&
                parse_vec(*resolved_angular_velocity, event.collision.contact.resolved_angular_velocity) &&
                number_value(*max_energy, event.collision.contact.max_kinetic_energy_joules) &&
                bool_value(*has_resolved, has_resolved_state) &&
                (event.collision.contact.touching = touching, event.collision.contact.has_resolved_state = has_resolved_state, true);
    }
    case ReplayEventType::SceneObject: {
        std::string operation;
        const JsonValue *operation_value = field(value, "operation");
        const JsonValue *name = field(value, "name");
        const JsonValue *asset_id = field(value, "asset_id");
        const JsonValue *position = field(value, "position");
        const JsonValue *orientation = field(value, "orientation");
        return operation_value != nullptr && name != nullptr && asset_id != nullptr && position != nullptr &&
                orientation != nullptr && string_value(*operation_value, operation) && parse_object_operation(operation, event.object_operation) &&
                string_value(*name, event.object_name) && string_value(*asset_id, event.object_asset_id) &&
                parse_vec(*position, event.object_position) && parse_quat(*orientation, event.object_orientation);
    }
    case ReplayEventType::Environment: {
        const JsonValue *state = field(value, "state");
        if (state == nullptr || state->type != JsonValue::Type::Object) {
            return false;
        }
        event.environment_json = compact_json(*state);
        return true;
    }
    }
    return false;
}

bool same_or_close(double expected, double actual, double tolerance) {
    return std::isfinite(expected) && std::isfinite(actual) && std::abs(expected - actual) <= tolerance;
}

std::string divergence_number(double value) {
    return compact_number(value);
}

} // namespace

bool ReplaySessionRecorder::fail(ReplayDiagnosticCode code, std::string message) {
    diagnostic_ = {code, std::move(message)};
    return false;
}

bool ReplaySessionRecorder::has_vehicle(const std::string &vehicle_name) const {
    return std::any_of(session_.vehicles.begin(), session_.vehicles.end(), [&](const ReplayVehicleConfig &vehicle) {
        return vehicle.name == vehicle_name;
    });
}

ReplaySessionRecorder::ReplaySessionRecorder(std::uint64_t seed, std::string settings_manifest_hash) {
    session_.seed = seed;
    session_.settings_manifest_hash = std::move(settings_manifest_hash);
}

bool ReplaySessionRecorder::add_vehicle(
        std::string vehicle_name,
        std::string config_manifest_hash,
        std::string config_json,
        ReplayControllerAuthority controller_authority) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!valid_identity(vehicle_name) || has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::InvalidIdentity, "invalid or duplicate replay vehicle identity: " + vehicle_name);
    }
    if (config_manifest_hash.empty() || config_json.empty()) {
        return fail(ReplayDiagnosticCode::MissingVehicleConfig, "vehicle config is required: " + vehicle_name);
    }
    JsonValue parsed;
    JsonParser parser(config_json);
    if (!parser.parse(parsed) || parsed.type != JsonValue::Type::Object) {
        return fail(ReplayDiagnosticCode::MissingVehicleConfig, "vehicle config must be a JSON object: " + vehicle_name);
    }
    session_.vehicles.push_back({std::move(vehicle_name), std::move(config_manifest_hash), compact_json(parsed), controller_authority});
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_command(
        std::uint64_t timestamp_us,
        const std::string &vehicle_name,
        const FlightCommand &command,
        ReplayControllerAuthority controller_authority) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + vehicle_name);
    }
    if (!finite_command(command)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay command contains a non-finite value");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Command;
    event.vehicle_name = vehicle_name;
    event.controller_authority = controller_authority;
    event.command = command;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_async_command(
        std::uint64_t timestamp_us,
        const std::string &vehicle_name,
        const std::string &command_id,
        const std::string &method,
        ReplayAsyncLifecycle lifecycle) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + vehicle_name);
    }
    if (command_id.empty() || method.empty()) {
        return fail(ReplayDiagnosticCode::InvalidLifecycle, "async replay command id and method are required");
    }
    const std::string key = async_lifecycle_key(vehicle_name, command_id);
    const auto current = async_lifecycle_.find(key);
    const auto method_it = async_methods_.find(key);
    if (method_it != async_methods_.end() && method_it->second != method) {
        return fail(ReplayDiagnosticCode::InvalidLifecycle, "async replay method changed for command: " + command_id);
    }
    bool allowed = false;
    if (lifecycle == ReplayAsyncLifecycle::Submitted) {
        allowed = current == async_lifecycle_.end();
    } else if (current != async_lifecycle_.end()) {
        if (current->second == ReplayAsyncLifecycle::Submitted) {
            allowed = lifecycle == ReplayAsyncLifecycle::Accepted;
        } else if (current->second == ReplayAsyncLifecycle::Accepted) {
            allowed = lifecycle == ReplayAsyncLifecycle::Completed ||
                    lifecycle == ReplayAsyncLifecycle::Cancelled ||
                    lifecycle == ReplayAsyncLifecycle::TimedOut;
        }
    }
    if (!allowed) {
        return fail(ReplayDiagnosticCode::InvalidLifecycle, "invalid async replay lifecycle for command: " + command_id);
    }
    async_lifecycle_[key] = lifecycle;
    async_methods_[key] = method;
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::AsyncCommand;
    event.vehicle_name = vehicle_name;
    event.command_id = command_id;
    event.command_method = method;
    event.command_lifecycle = lifecycle;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_simulation_operation(
        std::uint64_t timestamp_us,
        ReplaySimulationOperation operation,
        std::int64_t value) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if ((operation == ReplaySimulationOperation::StepFrames || operation == ReplaySimulationOperation::StepSeconds) && value < 0) {
        return fail(ReplayDiagnosticCode::InvalidSession, "simulation step value must not be negative");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::SimulationTime;
    event.simulation_operation = operation;
    event.simulation_value = value;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_collision(
        std::uint64_t timestamp_us,
        const std::string &vehicle_name,
        const CollisionContact &contact,
        ReplayControllerAuthority controller_authority) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + vehicle_name);
    }
    if (!finite_vec(contact.normal) || !finite_vec(contact.impulse) || !finite_vec(contact.resolved_velocity) ||
            !finite_vec(contact.resolved_angular_velocity) || !std::isfinite(contact.restitution) ||
            !std::isfinite(contact.max_kinetic_energy_joules)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "collision replay data must be finite");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Collision;
    event.vehicle_name = vehicle_name;
    event.collision = {controller_authority, contact};
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_scene_object(
        std::uint64_t timestamp_us,
        ReplaySceneObjectOperation operation,
        std::string object_name,
        std::string asset_id,
        const Vec3 &position,
        const Quat &orientation) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if ((operation != ReplaySceneObjectOperation::Reset && object_name.empty()) ||
            !finite_vec(position) || !finite_quat(orientation)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "invalid replay scene object event");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::SceneObject;
    event.object_operation = operation;
    event.object_name = std::move(object_name);
    event.object_asset_id = std::move(asset_id);
    event.object_position = position;
    event.object_orientation = orientation;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_environment(std::uint64_t timestamp_us, std::string environment_json) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    JsonValue parsed;
    JsonParser parser(environment_json);
    if (!parser.parse(parsed) || parsed.type != JsonValue::Type::Object) {
        return fail(ReplayDiagnosticCode::Corrupt, "environment replay state must be a JSON object");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Environment;
    event.environment_json = compact_json(parsed);
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::finish(std::uint64_t timestamp_us, std::string reason) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (reason.empty()) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay termination reason is required");
    }
    for (const auto &entry : async_lifecycle_) {
        if (entry.second == ReplayAsyncLifecycle::Submitted || entry.second == ReplayAsyncLifecycle::Accepted) {
            return fail(ReplayDiagnosticCode::InvalidLifecycle, "async replay command did not reach a terminal lifecycle");
        }
    }
    session_.termination_timestamp_us = timestamp_us;
    session_.termination_reason = std::move(reason);
    const ReplayDiagnostic validation = validate_session(session_, true);
    if (!validation.ok()) {
        session_.termination_timestamp_us = 0;
        session_.termination_reason.clear();
        diagnostic_ = validation;
        return false;
    }
    finished_ = true;
    diagnostic_ = {};
    return true;
}

const ReplaySession &ReplaySessionRecorder::session() const {
    return session_;
}

const ReplayDiagnostic &ReplaySessionRecorder::diagnostic() const {
    return diagnostic_;
}

std::string ReplaySessionRecorder::serialize() const {
    return serialize_replay_session(session_);
}

std::string serialize_replay_session(const ReplaySession &session) {
    if (!validate_session(session, true).ok()) {
        return {};
    }
    std::string result = "{\"schema_version\":" + std::to_string(session.schema_version) +
            ",\"seed\":" + std::to_string(session.seed) +
            ",\"settings_manifest_hash\":\"" + escape_json_string(session.settings_manifest_hash) + "\",\"vehicles\":[";
    for (std::size_t index = 0; index < session.vehicles.size(); ++index) {
        if (index != 0) {
            result += ',';
        }
        const ReplayVehicleConfig &vehicle = session.vehicles[index];
        result += "{\"name\":\"" + escape_json_string(vehicle.name) +
                "\",\"config_manifest_hash\":\"" + escape_json_string(vehicle.config_manifest_hash) +
                "\",\"controller_authority\":\"" + authority_name(vehicle.controller_authority) +
                "\",\"config\":" + vehicle.config_json + '}';
    }
    result += "],\"events\":[";
    for (std::size_t index = 0; index < session.events.size(); ++index) {
        if (index != 0) {
            result += ',';
        }
        result += event_json(session.events[index]);
    }
    result += "],\"termination\":{\"timestamp_us\":" + std::to_string(session.termination_timestamp_us) +
            ",\"reason\":\"" + escape_json_string(session.termination_reason) + "\"}}";
    return result;
}

ReplayLoadResult load_replay_session(
        const std::string &serialized,
        const std::string &expected_settings_manifest_hash) {
    if (serialized.empty()) {
        return {false, {}, invalid(ReplayDiagnosticCode::Empty, "replay is empty")};
    }
    JsonValue root;
    JsonParser parser(serialized);
    if (!parser.parse(root)) {
        return {false, {}, invalid(parser.truncated() ? ReplayDiagnosticCode::Truncated : ReplayDiagnosticCode::Corrupt, parser.error())};
    }
    if (root.type != JsonValue::Type::Object) {
        return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay root must be an object")};
    }
    ReplaySession session;
    const JsonValue *schema = field(root, "schema_version");
    const JsonValue *seed = field(root, "seed");
    const JsonValue *manifest = field(root, "settings_manifest_hash");
    const JsonValue *vehicles = field(root, "vehicles");
    const JsonValue *events = field(root, "events");
    const JsonValue *termination = field(root, "termination");
    double schema_number = 0.0;
    if (schema == nullptr || !number_value(*schema, schema_number) || std::floor(schema_number) != schema_number) {
        return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay schema_version is required")};
    }
    session.schema_version = static_cast<std::int32_t>(schema_number);
    if (session.schema_version != kCompleteReplaySchemaVersion) {
        return {false, {}, invalid(ReplayDiagnosticCode::UnsupportedSchema, "unsupported replay schema version: " + std::to_string(session.schema_version))};
    }
    if (manifest == nullptr || !string_value(*manifest, session.settings_manifest_hash) || session.settings_manifest_hash.empty()) {
        return {false, {}, invalid(ReplayDiagnosticCode::MissingManifest, "replay settings manifest hash is required")};
    }
    if (!expected_settings_manifest_hash.empty() && session.settings_manifest_hash != expected_settings_manifest_hash) {
        return {false, {}, invalid(ReplayDiagnosticCode::IncompatibleManifest, "replay settings manifest hash is incompatible")};
    }
    if (seed == nullptr || !integer_value(*seed, session.seed) || vehicles == nullptr || vehicles->type != JsonValue::Type::Array) {
        return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay seed and vehicles are required")};
    }
    for (const JsonValue &value : vehicles->array) {
        const JsonValue *name = field(value, "name");
        const JsonValue *hash = field(value, "config_manifest_hash");
        const JsonValue *authority = field(value, "controller_authority");
        const JsonValue *config = field(value, "config");
        ReplayVehicleConfig vehicle;
        std::string authority_name_value;
        if (name == nullptr || hash == nullptr || authority == nullptr || config == nullptr ||
                !string_value(*name, vehicle.name) || !valid_identity(vehicle.name) ||
                !string_value(*hash, vehicle.config_manifest_hash) || vehicle.config_manifest_hash.empty() ||
                !string_value(*authority, authority_name_value) || !parse_authority(authority_name_value, vehicle.controller_authority) ||
                config->type != JsonValue::Type::Object) {
            const ReplayDiagnosticCode code = name != nullptr && !valid_identity(name->string) ?
                    ReplayDiagnosticCode::InvalidIdentity : ReplayDiagnosticCode::MissingVehicleConfig;
            return {false, {}, invalid(code, "invalid or incomplete replay vehicle config")};
        }
        vehicle.config_json = compact_json(*config);
        if (std::any_of(session.vehicles.begin(), session.vehicles.end(), [&](const ReplayVehicleConfig &existing) {
            return existing.name == vehicle.name;
        })) {
            return {false, {}, invalid(ReplayDiagnosticCode::InvalidIdentity, "duplicate replay vehicle identity: " + vehicle.name)};
        }
        session.vehicles.push_back(std::move(vehicle));
    }
    if (events == nullptr || events->type != JsonValue::Type::Array) {
        return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay events are required")};
    }
    for (const JsonValue &value : events->array) {
        ReplayEvent event;
        if (!parse_event(value, event)) {
            return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "invalid replay event")};
        }
        session.events.push_back(std::move(event));
    }
    if (termination == nullptr || termination->type != JsonValue::Type::Object) {
        return {false, {}, invalid(ReplayDiagnosticCode::Truncated, "replay termination is missing")};
    }
    const JsonValue *termination_timestamp = field(*termination, "timestamp_us");
    const JsonValue *termination_reason = field(*termination, "reason");
    if (termination_timestamp == nullptr || termination_reason == nullptr ||
            !integer_value(*termination_timestamp, session.termination_timestamp_us) ||
            !string_value(*termination_reason, session.termination_reason) || session.termination_reason.empty()) {
        return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay termination is invalid")};
    }
    const ReplayDiagnostic validation = validate_session(session, true);
    if (!validation.ok()) {
        return {false, {}, validation};
    }
    std::unordered_map<std::string, ReplayAsyncLifecycle> lifecycle;
    std::unordered_map<std::string, std::string> methods;
    for (const ReplayEvent &event : session.events) {
        if (event.type != ReplayEventType::AsyncCommand) {
            continue;
        }
        const auto current = lifecycle.find(async_lifecycle_key(event.vehicle_name, event.command_id));
        const std::string key = async_lifecycle_key(event.vehicle_name, event.command_id);
        const auto method = methods.find(key);
        if (method != methods.end() && method->second != event.command_method) {
            return {false, {}, invalid(ReplayDiagnosticCode::InvalidLifecycle, "async replay method changed for command: " + event.command_id)};
        }
        bool allowed = false;
        if (event.command_lifecycle == ReplayAsyncLifecycle::Submitted) {
            allowed = current == lifecycle.end();
        } else if (current != lifecycle.end() && current->second == ReplayAsyncLifecycle::Submitted) {
            allowed = event.command_lifecycle == ReplayAsyncLifecycle::Accepted;
        } else if (current != lifecycle.end() && current->second == ReplayAsyncLifecycle::Accepted) {
            allowed = event.command_lifecycle == ReplayAsyncLifecycle::Completed ||
                    event.command_lifecycle == ReplayAsyncLifecycle::Cancelled ||
                    event.command_lifecycle == ReplayAsyncLifecycle::TimedOut;
        }
        if (!allowed) {
            return {false, {}, invalid(ReplayDiagnosticCode::InvalidLifecycle, "invalid async replay lifecycle for command: " + event.command_id)};
        }
        lifecycle[key] = event.command_lifecycle;
        methods[key] = event.command_method;
    }
    return {true, std::move(session), {}};
}

ReplayRunResult replay_session(
        const ReplaySession &session,
        const DualAircraftConfig &config) {
    const ReplayDiagnostic validation = validate_session(session, true);
    if (!validation.ok()) {
        return {false, validation, {}, {}};
    }
    if (config.upper.physics_hz <= 0 || config.upper.substep_hz <= 0 ||
            config.lower.physics_hz != config.upper.physics_hz ||
            config.lower.substep_hz != config.upper.substep_hz ||
            config.upper.mass_kg <= 0.0 || config.lower.mass_kg <= 0.0 ||
            !validate_per_motor_config(config.upper.per_motor) ||
            !validate_per_motor_config(config.lower.per_motor)) {
        return {false, invalid(ReplayDiagnosticCode::InvalidSession, "replay runtime configuration is invalid"), {}, {}};
    }

    DualAircraftState state{config.upper.initial_state, config.lower.initial_state};
    SimulationClock clocks[2];
    FlightController controllers[2];
    controllers[0].arm(0.0);
    controllers[1].arm(0.0);
    CollisionAuthoritySwitch collision_switches[2];
    FlightCommand commands[2];
    bool paused = false;
    double frame_remainder = 0.0;
    std::uint64_t previous_timestamp_us = 0;
    const auto vehicle_index = [&](const std::string &name) {
        return name == session.vehicles[0].name ? 0 : name == session.vehicles[1].name ? 1 : -1;
    };
    const auto step_frame = [&]() {
        controllers[0].step_angle_mode(state.upper, clocks[0], config.upper, commands[0]);
        controllers[1].step_angle_mode(state.lower, clocks[1], config.lower, commands[1]);
    };
    const auto step_frames = [&](std::int64_t count) {
        for (std::int64_t frame = 0; frame < count; ++frame) {
            step_frame();
        }
    };
    const auto advance_us = [&](std::uint64_t duration_us) {
        const double frames = frame_remainder +
                static_cast<double>(duration_us) * static_cast<double>(config.upper.physics_hz) / 1000000.0;
        const auto frame_count = static_cast<std::int64_t>(std::floor(frames));
        frame_remainder = frames - static_cast<double>(frame_count);
        step_frames(frame_count);
    };

    for (const ReplayEvent &event : session.events) {
        if (!paused && event.timestamp_us >= previous_timestamp_us) {
            advance_us(event.timestamp_us - previous_timestamp_us);
        }
        previous_timestamp_us = event.timestamp_us;
        switch (event.type) {
        case ReplayEventType::Command: {
            const int index = vehicle_index(event.vehicle_name);
            if (index < 0) {
                return {false, invalid(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + event.vehicle_name), {}, {}};
            }
            commands[index] = event.command;
            break;
        }
        case ReplayEventType::AsyncCommand:
        case ReplayEventType::SceneObject:
        case ReplayEventType::Environment:
            break;
        case ReplayEventType::Collision: {
            const int index = vehicle_index(event.vehicle_name);
            if (index < 0) {
                return {false, invalid(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + event.vehicle_name), {}, {}};
            }
            if (index == 0) {
                collision_switches[index].step(state.upper, clocks[index], controllers[index], config.upper, commands[index], event.collision.contact);
            } else {
                collision_switches[index].step(state.lower, clocks[index], controllers[index], config.lower, commands[index], event.collision.contact);
            }
            break;
        }
        case ReplayEventType::SimulationTime:
            switch (event.simulation_operation) {
            case ReplaySimulationOperation::Pause:
                paused = true;
                break;
            case ReplaySimulationOperation::Resume:
                paused = false;
                break;
            case ReplaySimulationOperation::StepFrames:
                step_frames(event.simulation_value);
                break;
            case ReplaySimulationOperation::StepSeconds:
                advance_us(static_cast<std::uint64_t>(event.simulation_value) * 1000000ULL);
                break;
            case ReplaySimulationOperation::Reset:
                state = {};
                clocks[0] = {};
                clocks[1] = {};
                commands[0] = {};
                commands[1] = {};
                controllers[0].reset_flight(state.upper, clocks[0]);
                controllers[1].reset_flight(state.lower, clocks[1]);
                frame_remainder = 0.0;
                break;
            case ReplaySimulationOperation::Respawn:
                state = {config.upper.initial_state, config.lower.initial_state};
                clocks[0] = {};
                clocks[1] = {};
                commands[0] = {};
                commands[1] = {};
                controllers[0].reset_flight(state.upper, clocks[0]);
                controllers[1].reset_flight(state.lower, clocks[1]);
                frame_remainder = 0.0;
                break;
            }
            break;
        }
    }
    return {true, {}, state, clocks[0]};
}

ReplayDivergence compare_replay_sessions(
        const ReplaySession &expected,
        const ReplaySession &actual,
        double numeric_tolerance) {
    const double tolerance = std::max(0.0, numeric_tolerance);
    ReplayDivergence result;
    const auto report = [&](std::uint64_t timestamp_us, const std::string &vehicle, const std::string &field_name,
                            const std::string &expected_value, const std::string &actual_value, double field_tolerance) {
        result.diverged = true;
        result.timestamp_us = timestamp_us;
        result.vehicle_name = vehicle;
        result.field = field_name;
        result.expected = expected_value;
        result.actual = actual_value;
        result.tolerance = field_tolerance;
    };
    if (expected.seed != actual.seed) {
        report(0, {}, "seed", std::to_string(expected.seed), std::to_string(actual.seed), 0.0);
        return result;
    }
    if (expected.settings_manifest_hash != actual.settings_manifest_hash) {
        report(0, {}, "settings_manifest_hash", expected.settings_manifest_hash, actual.settings_manifest_hash, 0.0);
        return result;
    }
    if (expected.schema_version != actual.schema_version) {
        report(0, {}, "schema_version", std::to_string(expected.schema_version), std::to_string(actual.schema_version), 0.0);
        return result;
    }
    if (expected.vehicles.size() != actual.vehicles.size()) {
        report(0, {}, "vehicles.count", std::to_string(expected.vehicles.size()), std::to_string(actual.vehicles.size()), 0.0);
        return result;
    }
    for (std::size_t index = 0; index < expected.vehicles.size(); ++index) {
        const ReplayVehicleConfig &left = expected.vehicles[index];
        const ReplayVehicleConfig &right = actual.vehicles[index];
        if (left.name != right.name) {
            report(0, left.name, "vehicle.name", left.name, right.name, 0.0);
            return result;
        }
        if (left.config_manifest_hash != right.config_manifest_hash) {
            report(0, left.name, "vehicle.config_manifest_hash", left.config_manifest_hash, right.config_manifest_hash, 0.0);
            return result;
        }
        if (left.config_json != right.config_json) {
            report(0, left.name, "vehicle.config", left.config_json, right.config_json, 0.0);
            return result;
        }
        if (left.controller_authority != right.controller_authority) {
            report(0, left.name, "vehicle.controller_authority", authority_name(left.controller_authority), authority_name(right.controller_authority), 0.0);
            return result;
        }
    }
    if (expected.events.size() != actual.events.size()) {
        const std::size_t index = std::min(expected.events.size(), actual.events.size());
        const std::uint64_t timestamp = index < expected.events.size() ? expected.events[index].timestamp_us : actual.events[index].timestamp_us;
        report(timestamp, index < expected.events.size() ? expected.events[index].vehicle_name : actual.events[index].vehicle_name,
                "events.count", std::to_string(expected.events.size()), std::to_string(actual.events.size()), 0.0);
        return result;
    }
    for (std::size_t index = 0; index < expected.events.size(); ++index) {
        const ReplayEvent &left = expected.events[index];
        const ReplayEvent &right = actual.events[index];
        if (left.timestamp_us != right.timestamp_us) {
            report(std::min(left.timestamp_us, right.timestamp_us), left.vehicle_name, "timestamp_us",
                    std::to_string(left.timestamp_us), std::to_string(right.timestamp_us), 0.0);
            return result;
        }
        if (left.vehicle_name != right.vehicle_name) {
            report(left.timestamp_us, left.vehicle_name, "vehicle", left.vehicle_name, right.vehicle_name, 0.0);
            return result;
        }
        if (left.type != right.type) {
            report(left.timestamp_us, left.vehicle_name, "type", event_type_name(left.type), event_type_name(right.type), 0.0);
            return result;
        }
        if (left.type == ReplayEventType::Command && left.controller_authority != right.controller_authority) {
            report(left.timestamp_us, left.vehicle_name, "command.authority", authority_name(left.controller_authority), authority_name(right.controller_authority), 0.0);
            return result;
        }
        if (left.type == ReplayEventType::Command) {
            const double left_values[] = {left.command.throttle, left.command.roll_degrees, left.command.pitch_degrees, left.command.yaw_rate_degrees_per_second};
            const double right_values[] = {right.command.throttle, right.command.roll_degrees, right.command.pitch_degrees, right.command.yaw_rate_degrees_per_second};
            const char *fields[] = {"command.throttle", "command.roll_degrees", "command.pitch_degrees", "command.yaw_rate_degrees_per_second"};
            for (int value_index = 0; value_index < 4; ++value_index) {
                if (!same_or_close(left_values[value_index], right_values[value_index], tolerance)) {
                    report(left.timestamp_us, left.vehicle_name, fields[value_index], divergence_number(left_values[value_index]), divergence_number(right_values[value_index]), tolerance);
                    return result;
                }
            }
        } else if (left.type == ReplayEventType::AsyncCommand) {
            if (left.command_id != right.command_id) {
                report(left.timestamp_us, left.vehicle_name, "async.command_id", left.command_id, right.command_id, 0.0);
                return result;
            }
            if (left.command_method != right.command_method) {
                report(left.timestamp_us, left.vehicle_name, "async.method", left.command_method, right.command_method, 0.0);
                return result;
            }
            if (left.command_lifecycle != right.command_lifecycle) {
                report(left.timestamp_us, left.vehicle_name, "async.lifecycle", lifecycle_name(left.command_lifecycle), lifecycle_name(right.command_lifecycle), 0.0);
                return result;
            }
        } else if (left.type == ReplayEventType::SimulationTime) {
            if (left.simulation_operation != right.simulation_operation) {
                report(left.timestamp_us, {}, "simulation.operation", simulation_operation_name(left.simulation_operation), simulation_operation_name(right.simulation_operation), 0.0);
                return result;
            }
            if (left.simulation_value != right.simulation_value) {
                report(left.timestamp_us, {}, "simulation.value", std::to_string(left.simulation_value), std::to_string(right.simulation_value), 0.0);
                return result;
            }
        } else if (left.type == ReplayEventType::Collision &&
                (left.collision.authority != right.collision.authority ||
                 left.collision.contact.touching != right.collision.contact.touching ||
                 !same_or_close(left.collision.contact.normal.x, right.collision.contact.normal.x, tolerance) ||
                 !same_or_close(left.collision.contact.normal.y, right.collision.contact.normal.y, tolerance) ||
                 !same_or_close(left.collision.contact.normal.z, right.collision.contact.normal.z, tolerance) ||
                 !same_or_close(left.collision.contact.impulse.x, right.collision.contact.impulse.x, tolerance) ||
                 !same_or_close(left.collision.contact.impulse.y, right.collision.contact.impulse.y, tolerance) ||
                 !same_or_close(left.collision.contact.impulse.z, right.collision.contact.impulse.z, tolerance) ||
                 !same_or_close(left.collision.contact.restitution, right.collision.contact.restitution, tolerance) ||
                 left.collision.contact.has_resolved_state != right.collision.contact.has_resolved_state ||
                 !same_or_close(left.collision.contact.resolved_velocity.x, right.collision.contact.resolved_velocity.x, tolerance) ||
                 !same_or_close(left.collision.contact.resolved_velocity.y, right.collision.contact.resolved_velocity.y, tolerance) ||
                 !same_or_close(left.collision.contact.resolved_velocity.z, right.collision.contact.resolved_velocity.z, tolerance) ||
                 !same_or_close(left.collision.contact.resolved_angular_velocity.x, right.collision.contact.resolved_angular_velocity.x, tolerance) ||
                 !same_or_close(left.collision.contact.resolved_angular_velocity.y, right.collision.contact.resolved_angular_velocity.y, tolerance) ||
                 !same_or_close(left.collision.contact.resolved_angular_velocity.z, right.collision.contact.resolved_angular_velocity.z, tolerance) ||
                 !same_or_close(left.collision.contact.max_kinetic_energy_joules, right.collision.contact.max_kinetic_energy_joules, tolerance))) {
            if (left.collision.authority != right.collision.authority) {
                report(left.timestamp_us, left.vehicle_name, "collision.authority", authority_name(left.collision.authority), authority_name(right.collision.authority), 0.0);
            } else if (left.collision.contact.normal.x != right.collision.contact.normal.x ||
                    left.collision.contact.normal.y != right.collision.contact.normal.y ||
                    left.collision.contact.normal.z != right.collision.contact.normal.z) {
                report(left.timestamp_us, left.vehicle_name, "collision.normal", vec_json(left.collision.contact.normal), vec_json(right.collision.contact.normal), tolerance);
            } else if (left.collision.contact.impulse.x != right.collision.contact.impulse.x ||
                    left.collision.contact.impulse.y != right.collision.contact.impulse.y ||
                    left.collision.contact.impulse.z != right.collision.contact.impulse.z) {
                report(left.timestamp_us, left.vehicle_name, "collision.impulse", vec_json(left.collision.contact.impulse), vec_json(right.collision.contact.impulse), tolerance);
            } else {
                report(left.timestamp_us, left.vehicle_name, "collision.contact", "different", "different", tolerance);
            }
            return result;
        } else if (left.type == ReplayEventType::SceneObject &&
                (left.object_operation != right.object_operation || left.object_name != right.object_name || left.object_asset_id != right.object_asset_id ||
                 !same_or_close(left.object_position.x, right.object_position.x, tolerance) ||
                 !same_or_close(left.object_position.y, right.object_position.y, tolerance) ||
                 !same_or_close(left.object_position.z, right.object_position.z, tolerance) ||
                 !same_or_close(left.object_orientation.x, right.object_orientation.x, tolerance) ||
                 !same_or_close(left.object_orientation.y, right.object_orientation.y, tolerance) ||
                 !same_or_close(left.object_orientation.z, right.object_orientation.z, tolerance) ||
                 !same_or_close(left.object_orientation.w, right.object_orientation.w, tolerance))) {
            if (left.object_name != right.object_name) {
                report(left.timestamp_us, {}, "scene_object.name", left.object_name, right.object_name, 0.0);
            } else if (left.object_asset_id != right.object_asset_id) {
                report(left.timestamp_us, {}, "scene_object.asset_id", left.object_asset_id, right.object_asset_id, 0.0);
            } else {
                report(left.timestamp_us, {}, "scene_object.transform", vec_json(left.object_position), vec_json(right.object_position), tolerance);
            }
            return result;
        } else if (left.type == ReplayEventType::Environment && left.environment_json != right.environment_json) {
            report(left.timestamp_us, {}, "environment", left.environment_json, right.environment_json, 0.0);
            return result;
        }
    }
    if (expected.termination_timestamp_us != actual.termination_timestamp_us) {
        report(std::min(expected.termination_timestamp_us, actual.termination_timestamp_us), {}, "termination.timestamp_us",
                std::to_string(expected.termination_timestamp_us), std::to_string(actual.termination_timestamp_us), 0.0);
    } else if (expected.termination_reason != actual.termination_reason) {
        report(expected.termination_timestamp_us, {}, "termination.reason", expected.termination_reason, actual.termination_reason, 0.0);
    }
    return result;
}

} // namespace aerosim
