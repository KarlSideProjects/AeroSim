#include "aerosim_replay.hpp"
#include "aerosim_wind.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <limits>
#include <map>
#include <new>
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

bool checked_batch_frame_count(double seconds, std::int32_t physics_hz, std::size_t &frames) {
    if (!std::isfinite(seconds) || seconds < 0.0 || physics_hz <= 0) {
        return false;
    }
    const long double requested = std::ceil(static_cast<long double>(seconds) * static_cast<long double>(physics_hz));
    if (!std::isfinite(requested) || requested < 0.0L ||
            requested > static_cast<long double>(kMaxBatchTrajectoryFrames) ||
            requested > static_cast<long double>(std::numeric_limits<std::size_t>::max())) {
        return false;
    }
    frames = static_cast<std::size_t>(requested);
    return true;
}

} // namespace

ReplayBatchResult replay_angle_mode_seconds_batch_with_wind(
        const SimulationConfig &config,
        const FlightCommand &command,
        double seconds,
        const WindField *wind_field);

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
    return replay_angle_mode_batch(config, inputs).rows;
}

ReplayBatchResult replay_angle_mode_batch(
        const SimulationConfig &config,
        const RecordedInputSequence &inputs,
        const WindField *wind_field) {
    if (inputs.frames.size() > kMaxBatchTrajectoryFrames) {
        return {StepStatus::ResourceLimitExceeded, {}, kNoFailedReplayFrame};
    }
    ReplayBatchResult result;
#if defined(__cpp_exceptions)
    try {
        result.rows.reserve(inputs.frames.size());
    } catch (const std::bad_alloc &) {
        result.status = StepStatus::ResourceLimitExceeded;
        return result;
    }
#else
    result.rows.reserve(inputs.frames.size());
#endif
    RigidBodyState state = config.initial_state;
    SimulationClock clock;
    FlightController controller;
    controller.arm(0.0);
    for (std::size_t frame = 0; frame < inputs.frames.size(); ++frame) {
        SimulationConfig frame_config = config;
        if (wind_field != nullptr) {
            const double time_seconds = static_cast<double>(clock.total_substeps) /
                    static_cast<double>(std::max(1, config.substep_hz));
            frame_config.wind_world_mps = wind_field->sample(time_seconds, state.position);
            frame_config.wind_turbulence_mps = wind_field->turbulence(time_seconds);
        }
        const StepResult step = controller.try_step_angle_mode(state, clock, frame_config, inputs.frames[frame], state.orientation);
        if (step.status != StepStatus::Ok) {
            result.status = step.status;
            result.failed_frame = frame;
            result.rows.clear();
            return result;
        }
        result.rows.push_back(step.sample);
    }
    return result;
}

ReplayBatchResult replay_angle_mode_seconds_batch(
        const SimulationConfig &config,
        const FlightCommand &command,
        double seconds) {
    return replay_angle_mode_seconds_batch_with_wind(config, command, seconds, nullptr);
}

ReplayBatchResult replay_angle_mode_seconds_batch(
        const SimulationConfig &config,
        const FlightCommand &command,
        double seconds,
        const WindField &wind_field) {
    return replay_angle_mode_seconds_batch_with_wind(config, command, seconds, &wind_field);
}

ReplayBatchResult replay_angle_mode_seconds_batch_with_wind(
        const SimulationConfig &config,
        const FlightCommand &command,
        double seconds,
        const WindField *wind_field) {
    if (!std::isfinite(seconds) || seconds < 0.0 || config.physics_hz <= 0) {
        return {StepStatus::InvalidConfig, {}, kNoFailedReplayFrame};
    }
    std::size_t frame_count = 0;
    if (!checked_batch_frame_count(seconds, config.physics_hz, frame_count)) {
        return {StepStatus::ResourceLimitExceeded, {}, kNoFailedReplayFrame};
    }
    RecordedInputSequence inputs;
#if defined(__cpp_exceptions)
    try {
        inputs.frames.assign(frame_count, command);
    } catch (const std::bad_alloc &) {
        return {StepStatus::ResourceLimitExceeded, {}, kNoFailedReplayFrame};
    }
#else
    inputs.frames.assign(frame_count, command);
#endif
    return replay_angle_mode_batch(config, inputs, wind_field);
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
    char buffer[64];
    const auto result = std::to_chars(
            std::begin(buffer), std::end(buffer), value, std::chars_format::general, std::numeric_limits<double>::max_digits10);
    return result.ec == std::errc{} ? std::string(buffer, result.ptr) : "0";
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

bool valid_replay_command(const FlightCommand &command) {
    return valid_flight_command(command);
}

bool valid_replay_acro_command(const AcroCommand &command) {
    return valid_acro_command(command);
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

bool parse_vec_object_or_array(const JsonValue &value, Vec3 &result) {
    if (parse_vec(value, result)) {
        return true;
    }
    const JsonValue *x = field(value, "x");
    const JsonValue *y = field(value, "y");
    const JsonValue *z = field(value, "z");
    return x != nullptr && y != nullptr && z != nullptr && number_value(*x, result.x) &&
            number_value(*y, result.y) && number_value(*z, result.z);
}

bool integer_value(const JsonValue &value, std::uint64_t &result);

bool parse_environment_config(
        const std::string &serialized,
        WindConfig &wind_config,
        double &air_density) {
    JsonValue root;
    JsonParser parser(serialized);
    if (!parser.parse(root) || root.type != JsonValue::Type::Object) {
        return false;
    }
    const JsonValue *atmosphere = field(root, "atmosphere");
    if (atmosphere == nullptr || atmosphere->type != JsonValue::Type::Object) {
        return false;
    }
    const JsonValue *preset = field(*atmosphere, "preset");
    std::string preset_name;
    if (preset == nullptr || !string_value(*preset, preset_name)) {
        return false;
    }
    if (preset_name == "light") {
        wind_config = wind_preset(WindPreset::Light);
    } else if (preset_name == "moderate") {
        wind_config = wind_preset(WindPreset::Moderate);
    } else if (preset_name == "severe") {
        wind_config = wind_preset(WindPreset::Severe);
    } else if (!preset_name.empty() && preset_name != "calm" && preset_name != "custom") {
        return false;
    }
    const JsonValue *steady_wind = field(*atmosphere, "steady_wind");
    if (steady_wind == nullptr || !parse_vec_object_or_array(*steady_wind, wind_config.steady_wind_mps)) {
        return false;
    }
    const JsonValue *turbulence = field(*atmosphere, "turbulence_sigma");
    if (turbulence == nullptr || !parse_vec_object_or_array(*turbulence, wind_config.turbulence_sigma_mps)) {
        return false;
    }
    const auto parse_number = [&](const char *key, double &target) {
        const JsonValue *value = field(*atmosphere, key);
        return value != nullptr && number_value(*value, target);
    };
    if (!parse_number("reference_airspeed_mps", wind_config.reference_airspeed_mps) ||
            !parse_number("scale_length_m", wind_config.scale_length_m) ||
            !parse_number("shear_reference_height_m", wind_config.shear_reference_height_m) ||
            !parse_number("shear_exponent", wind_config.shear_exponent)) {
        return false;
    }
    const JsonValue *shear_enabled = field(*atmosphere, "shear_enabled");
    if (shear_enabled == nullptr || !bool_value(*shear_enabled, wind_config.shear_enabled)) {
        return false;
    }
    const JsonValue *seed = field(*atmosphere, "seed");
    std::uint64_t seed_value = 0;
    if (seed == nullptr || !integer_value(*seed, seed_value) ||
            seed_value > std::numeric_limits<std::uint32_t>::max()) {
        return false;
    }
    wind_config.seed = static_cast<std::uint32_t>(seed_value);
    if (!std::isfinite(wind_config.reference_airspeed_mps) || wind_config.reference_airspeed_mps <= 0.0 ||
            !std::isfinite(wind_config.scale_length_m) || wind_config.scale_length_m <= 0.0 ||
            !std::isfinite(wind_config.shear_reference_height_m) || wind_config.shear_reference_height_m <= 0.0 ||
            !std::isfinite(wind_config.shear_exponent) || wind_config.shear_exponent < 0.0 ||
            !std::isfinite(wind_config.steady_wind_mps.x) || !std::isfinite(wind_config.steady_wind_mps.y) ||
            !std::isfinite(wind_config.steady_wind_mps.z) || !std::isfinite(wind_config.turbulence_sigma_mps.x) ||
            !std::isfinite(wind_config.turbulence_sigma_mps.y) || !std::isfinite(wind_config.turbulence_sigma_mps.z) ||
            wind_config.turbulence_sigma_mps.x < 0.0 || wind_config.turbulence_sigma_mps.y < 0.0 ||
            wind_config.turbulence_sigma_mps.z < 0.0) {
        return false;
    }
    const JsonValue *density = field(root, "atmosphere_air_density_kg_m3");
    if (density == nullptr || !number_value(*density, air_density) ||
            !std::isfinite(air_density) || air_density <= 0.0) {
        return false;
    }
    return true;
}

bool apply_environment_config(
        const std::string &serialized,
        SimulationConfig configs[2],
        WindField wind_fields[2]) {
    WindConfig wind_config;
    double air_density = 0.0;
    if (!parse_environment_config(serialized, wind_config, air_density)) {
        return false;
    }
    for (std::size_t index = 0; index < 2; ++index) {
        wind_fields[index].configure(wind_config);
        configs[index].wind_world_mps = wind_fields[index].sample(0.0, configs[index].initial_state.position);
        configs[index].wind_turbulence_mps = wind_fields[index].turbulence(0.0);
        configs[index].air_density_kg_m3 = air_density;
    }
    return true;
}

bool config_number_matches(double actual, double expected) {
    constexpr double kManifestTolerance = 1.0e-6;
    return std::abs(actual - expected) <= kManifestTolerance * std::max({1.0, std::abs(actual), std::abs(expected)});
}

bool json_number_matches(const JsonValue &root, const char *key, double expected) {
    const JsonValue *value = field(root, key);
    double actual = 0.0;
    return value != nullptr && number_value(*value, actual) && config_number_matches(actual, expected);
}

bool json_vec_matches(const JsonValue &root, const char *key, const Vec3 &expected) {
    const JsonValue *value = field(root, key);
    Vec3 actual;
    const bool matched = value != nullptr && parse_vec_object_or_array(*value, actual) &&
            config_number_matches(actual.x, expected.x) && config_number_matches(actual.y, expected.y) &&
            config_number_matches(actual.z, expected.z);
    return matched;
}

bool json_config_matches(const std::string &serialized, const SimulationConfig &expected) {
    JsonValue root;
    JsonParser parser(serialized);
    if (!parser.parse(root) || root.type != JsonValue::Type::Object) {
        return false;
    }
    const std::pair<const char *, double> scalars[] = {
            {"mass_kg", expected.mass_kg}, {"gravity_mps2", expected.gravity_mps2},
            {"physics_hz", expected.physics_hz}, {"substep_hz", expected.substep_hz},
            {"max_total_thrust_newtons", expected.max_total_thrust_newtons}, {"hover_throttle", expected.hover_throttle},
            {"motor_tau_s", expected.motor_tau_s}, {"battery_nominal_voltage_v", expected.battery_nominal_voltage_v},
            {"battery_cells", expected.battery_cells}, {"battery_cell_resistance_ohm", expected.battery_cell_resistance_ohm},
            {"battery_remaining_mah", expected.battery_remaining_mah}, {"max_total_current_a", expected.max_total_current_a},
            {"max_motor_rpm", expected.max_motor_rpm}, {"altitude_hold_noise_deadband_m", expected.altitude_hold_noise_deadband_m},
    };
    for (const auto &scalar : scalars) {
        if (!json_number_matches(root, scalar.first, scalar.second)) {
            return false;
        }
    }
    if (!json_vec_matches(root, "external_force_world", expected.external_force_world)) {
        return false;
    }
    const JsonValue *per_motor_value = field(root, "per_motor");
    if (per_motor_value == nullptr || per_motor_value->type != JsonValue::Type::Object ||
            !json_vec_matches(*per_motor_value, "inertia_frd", expected.per_motor.inertia_kg_m2)) {
        return false;
    }
    const JsonValue *positions = field(*per_motor_value, "position_frd");
    const JsonValue *spins = field(*per_motor_value, "spin_direction");
    if (positions == nullptr || positions->type != JsonValue::Type::Array || positions->array.size() != 4 ||
            spins == nullptr || spins->type != JsonValue::Type::Array || spins->array.size() != 4) {
        return false;
    }
    for (std::size_t index = 0; index < 4; ++index) {
        Vec3 position;
        double spin = 0.0;
        if (!parse_vec_object_or_array(positions->array[index], position) ||
                !config_number_matches(position.x, expected.per_motor.position_frd[index].x) ||
                !config_number_matches(position.y, expected.per_motor.position_frd[index].y) ||
                !config_number_matches(position.z, expected.per_motor.position_frd[index].z) ||
                !number_value(spins->array[index], spin) || !config_number_matches(spin, expected.per_motor.spin_direction[index])) {
            return false;
        }
    }
    const std::pair<const char *, double> motor_scalars[] = {
            {"max_thrust_per_motor_newtons", expected.per_motor.max_thrust_per_motor_newtons},
            {"max_current_per_motor_a", expected.per_motor.max_current_per_motor_a},
            {"yaw_torque_per_newton", expected.per_motor.yaw_torque_per_newton},
    };
    for (const auto &scalar : motor_scalars) {
        if (!json_number_matches(*per_motor_value, scalar.first, scalar.second)) {
            return false;
        }
    }
    const JsonValue *a3 = field(root, "a3_drag");
    const JsonValue *a4 = field(root, "a4_ground_effect");
    const JsonValue *a5 = field(root, "a5_downwash");
    const JsonValue *a6 = field(root, "a6_propwash");
    const JsonValue *body_drag = field(root, "body_drag");
    if (a3 == nullptr || a3->type != JsonValue::Type::Object ||
            a4 == nullptr || a4->type != JsonValue::Type::Object ||
            a5 == nullptr || a5->type != JsonValue::Type::Object ||
            a6 == nullptr || a6->type != JsonValue::Type::Object ||
            body_drag == nullptr || body_drag->type != JsonValue::Type::Object) {
        return false;
    }
    bool enabled = false;
    const std::pair<const char *, double> a3_scalars[] = {
            {"coefficient_x_kg", expected.a3_drag.coefficient.x},
            {"coefficient_y_kg", expected.a3_drag.coefficient.y},
            {"coefficient_z_kg", expected.a3_drag.coefficient.z},
    };
    const JsonValue *a3_enabled = field(*a3, "enabled");
    if (a3_enabled == nullptr || !bool_value(*a3_enabled, enabled) || enabled != expected.a3_drag.enabled) {
        return false;
    }
    for (const auto &scalar : a3_scalars) {
        if (!json_number_matches(*a3, scalar.first, scalar.second)) {
            return false;
        }
    }
    const std::pair<const char *, double> a4_scalars[] = {
            {"kf", expected.a4_ground_effect.kf}, {"ground_effect_coeff", expected.a4_ground_effect.ground_effect_coeff},
            {"prop_radius_m", expected.a4_ground_effect.prop_radius_m}, {"height_clip_m", expected.a4_ground_effect.height_clip_m},
    };
    for (const auto &scalar : a4_scalars) {
        if (!json_number_matches(*a4, scalar.first, scalar.second)) {
            return false;
        }
    }
    const JsonValue *a4_enabled = field(*a4, "enabled");
    if (a4_enabled == nullptr || !bool_value(*a4_enabled, enabled) || enabled != expected.a4_ground_effect.enabled) {
        return false;
    }
    for (std::size_t index = 0; index < 4; ++index) {
        if (!json_number_matches(*a4, ("motor_" + std::to_string(index) + "_rpm").c_str(), expected.a4_ground_effect.motor_rpm[index])) {
            return false;
        }
    }
    const std::pair<const char *, double> a5_scalars[] = {
            {"prop_radius_m", expected.a5_downwash.prop_radius_m}, {"coeff_1", expected.a5_downwash.coeff_1},
            {"coeff_2", expected.a5_downwash.coeff_2}, {"coeff_3", expected.a5_downwash.coeff_3},
    };
    for (const auto &scalar : a5_scalars) {
        if (!json_number_matches(*a5, scalar.first, scalar.second)) {
            return false;
        }
    }
    const JsonValue *a5_enabled = field(*a5, "enabled");
    if (a5_enabled == nullptr || !bool_value(*a5_enabled, enabled) || enabled != expected.a5_downwash.enabled) {
        return false;
    }
    const std::pair<const char *, double> a6_scalars[] = {
            {"full_collective_angular_accel_rad_s2", expected.a6_propwash.full_collective_angular_accel_rad_s2},
            {"minimum_wake_entry_speed_mps", expected.a6_propwash.minimum_wake_entry_speed_mps},
            {"minimum_transverse_rate_rad_s", expected.a6_propwash.minimum_transverse_rate_rad_s},
    };
    const JsonValue *a6_enabled = field(*a6, "enabled");
    if (a6_enabled == nullptr || !bool_value(*a6_enabled, enabled) || enabled != expected.a6_propwash.enabled) {
        return false;
    }
    for (const auto &scalar : a6_scalars) {
        if (!json_number_matches(*a6, scalar.first, scalar.second)) {
            return false;
        }
    }
    const JsonValue *body_enabled = field(*body_drag, "enabled");
    if (body_enabled == nullptr || !bool_value(*body_enabled, enabled) || enabled != expected.body_drag.enabled ||
            !json_vec_matches(*body_drag, "drag_coefficient", expected.body_drag.drag_coefficient) ||
            !json_vec_matches(*body_drag, "frontal_area_m2", expected.body_drag.frontal_area_m2) ||
            !json_vec_matches(*body_drag, "center_of_pressure_frd_m", expected.body_drag.center_of_pressure_frd_m) ||
            !json_number_matches(*body_drag, "air_density_kg_m3", expected.air_density_kg_m3)) {
        return false;
    }
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

bool integer_value(const JsonValue &value, std::uint64_t &result);

const char *authority_name(ReplayControllerAuthority value);
bool parse_authority(const std::string &value, ReplayControllerAuthority &result);

std::string rigid_body_state_json(const RigidBodyState &state) {
    return "{\"position\":" + vec_json(state.position) +
            ",\"orientation\":" + quat_json(state.orientation) +
            ",\"velocity\":" + vec_json(state.velocity) +
            ",\"angular_velocity\":" + vec_json(state.angular_velocity) +
            ",\"propwash\":" + vec_json(state.propwash_disturbance_rad_s2) +
            ",\"motor_thrust\":[" + compact_number(state.motor_thrust_newtons[0]) + ',' +
            compact_number(state.motor_thrust_newtons[1]) + ',' + compact_number(state.motor_thrust_newtons[2]) + ',' +
            compact_number(state.motor_thrust_newtons[3]) + "]}";
}

bool parse_rigid_body_state(const JsonValue &value, RigidBodyState &state) {
    const JsonValue *position = field(value, "position");
    const JsonValue *orientation = field(value, "orientation");
    const JsonValue *velocity = field(value, "velocity");
    const JsonValue *angular_velocity = field(value, "angular_velocity");
    const JsonValue *propwash = field(value, "propwash");
    const JsonValue *motor_thrust = field(value, "motor_thrust");
    if (position == nullptr || orientation == nullptr || velocity == nullptr || angular_velocity == nullptr ||
            propwash == nullptr || motor_thrust == nullptr || motor_thrust->type != JsonValue::Type::Array ||
            motor_thrust->array.size() != state.motor_thrust_newtons.size() ||
            !parse_vec(*position, state.position) || !parse_quat(*orientation, state.orientation) ||
            !parse_vec(*velocity, state.velocity) || !parse_vec(*angular_velocity, state.angular_velocity) ||
            !parse_vec(*propwash, state.propwash_disturbance_rad_s2)) {
        return false;
    }
    for (std::size_t index = 0; index < state.motor_thrust_newtons.size(); ++index) {
        if (!number_value(motor_thrust->array[index], state.motor_thrust_newtons[index])) {
            return false;
        }
    }
    return true;
}

template <std::size_t N>
std::string number_array_json(const std::array<double, N> &values) {
    std::string result = "[";
    for (std::size_t index = 0; index < N; ++index) {
        result += (index == 0 ? "" : ",") + compact_number(values[index]);
    }
    return result + ']';
}

template <std::size_t N>
std::string bool_array_json(const std::array<bool, N> &values) {
    std::string result = "[";
    for (std::size_t index = 0; index < N; ++index) {
        result += (index == 0 ? "" : ",");
        result += values[index] ? "true" : "false";
    }
    return result + ']';
}

template <std::size_t N>
bool parse_number_array(const JsonValue &value, std::array<double, N> &result) {
    if (value.type != JsonValue::Type::Array || value.array.size() != N) {
        return false;
    }
    for (std::size_t index = 0; index < N; ++index) {
        if (!number_value(value.array[index], result[index])) {
            return false;
        }
    }
    return true;
}

template <std::size_t N>
bool parse_bool_array(const JsonValue &value, std::array<bool, N> &result) {
    if (value.type != JsonValue::Type::Array || value.array.size() != N) {
        return false;
    }
    for (std::size_t index = 0; index < N; ++index) {
        if (!bool_value(value.array[index], result[index])) {
            return false;
        }
    }
    return true;
}

std::string controller_state_json(const FlightControlState &state) {
    return "{\"target_angle\":" + vec_json(state.target_angle_frd) +
            ",\"target_rate\":" + vec_json(state.target_rate_frd) +
            ",\"integral\":" + number_array_json(state.rate_integral) +
            ",\"previous_error\":" + vec_json(state.previous_rate_error_frd) +
            ",\"derivative\":" + vec_json(state.filtered_rate_derivative_frd) +
            ",\"mode\":" + std::to_string(state.mode_family) +
            ",\"initialized\":" + (state.control_initialized ? "true" : "false") +
            ",\"altitude_captured\":" + (state.altitude_hold_captured ? "true" : "false") +
            ",\"altitude_just_captured\":" + (state.altitude_hold_just_captured ? "true" : "false") +
            ",\"motor_latches\":" + bool_array_json(state.motor_saturation_latched) +
            ",\"pid_latches\":" + bool_array_json(state.pid_saturation_latched) +
            ",\"motor_total\":" + compact_number(state.motor_thrust_newtons) + '}';
}

bool parse_controller_state(const JsonValue &value, FlightControlState &state) {
    const JsonValue *target_angle = field(value, "target_angle");
    const JsonValue *target_rate = field(value, "target_rate");
    const JsonValue *integral = field(value, "integral");
    const JsonValue *previous_error = field(value, "previous_error");
    const JsonValue *derivative = field(value, "derivative");
    const JsonValue *mode = field(value, "mode");
    const JsonValue *initialized = field(value, "initialized");
    const JsonValue *altitude_captured = field(value, "altitude_captured");
    const JsonValue *altitude_just_captured = field(value, "altitude_just_captured");
    const JsonValue *motor_latches = field(value, "motor_latches");
    const JsonValue *pid_latches = field(value, "pid_latches");
    const JsonValue *motor_total = field(value, "motor_total");
    double mode_number = 0.0;
    return target_angle != nullptr && target_rate != nullptr && integral != nullptr && previous_error != nullptr &&
            derivative != nullptr && mode != nullptr && initialized != nullptr && altitude_captured != nullptr &&
            altitude_just_captured != nullptr && motor_latches != nullptr && pid_latches != nullptr && motor_total != nullptr &&
            parse_vec(*target_angle, state.target_angle_frd) && parse_vec(*target_rate, state.target_rate_frd) &&
            parse_number_array(*integral, state.rate_integral) && parse_vec(*previous_error, state.previous_rate_error_frd) &&
            parse_vec(*derivative, state.filtered_rate_derivative_frd) && number_value(*mode, mode_number) &&
            std::isfinite(mode_number) && std::floor(mode_number) == mode_number && mode_number >= 0.0 && mode_number <= 2.0 &&
            bool_value(*initialized, state.control_initialized) && bool_value(*altitude_captured, state.altitude_hold_captured) &&
            bool_value(*altitude_just_captured, state.altitude_hold_just_captured) &&
            parse_bool_array(*motor_latches, state.motor_saturation_latched) &&
            parse_bool_array(*pid_latches, state.pid_saturation_latched) && number_value(*motor_total, state.motor_thrust_newtons) &&
            std::isfinite(state.motor_thrust_newtons) && (state.mode_family = static_cast<int>(mode_number), true);
}

std::string clock_json(const SimulationClock &clock) {
    return "{\"substep_accumulator\":" + compact_number(clock.substep_accumulator) +
            ",\"total_substeps\":" + std::to_string(clock.total_substeps) + '}';
}

bool parse_clock(const JsonValue &value, SimulationClock &clock) {
    const JsonValue *accumulator = field(value, "substep_accumulator");
    const JsonValue *substeps = field(value, "total_substeps");
    return accumulator != nullptr && substeps != nullptr && number_value(*accumulator, clock.substep_accumulator) &&
            std::isfinite(clock.substep_accumulator) && integer_value(*substeps, clock.total_substeps);
}

std::string trajectory_json(const TrajectorySample &sample) {
    return "{\"time_seconds\":" + compact_number(sample.time_seconds) +
            ",\"substeps\":" + std::to_string(sample.substeps) +
            ",\"state\":" + rigid_body_state_json(sample.state) +
            ",\"propwash_disturbance_rad_s2\":" + vec_json(sample.propwash_disturbance_rad_s2) + '}';
}

bool parse_trajectory(const JsonValue &value, TrajectorySample &sample) {
    const JsonValue *time = field(value, "time_seconds");
    const JsonValue *substeps = field(value, "substeps");
    const JsonValue *state = field(value, "state");
    const JsonValue *propwash = field(value, "propwash_disturbance_rad_s2");
    return time != nullptr && substeps != nullptr && state != nullptr && propwash != nullptr && number_value(*time, sample.time_seconds) &&
            std::isfinite(sample.time_seconds) && integer_value(*substeps, sample.substeps) &&
            parse_rigid_body_state(*state, sample.state) &&
            parse_vec(*propwash, sample.propwash_disturbance_rad_s2);
}

std::string checkpoint_json(const ReplayRunCheckpoint &checkpoint) {
    const auto collision_json = [](const ReplayCollision &collision) {
        const CollisionContact &contact = collision.contact;
        return "{\"authority\":\"" + std::string(authority_name(collision.authority)) +
                "\",\"touching\":" + (contact.touching ? "true" : "false") +
                ",\"normal\":" + vec_json(contact.normal) +
                ",\"impulse\":" + vec_json(contact.impulse) +
                ",\"restitution\":" + compact_number(contact.restitution) +
                ",\"resolved_velocity\":" + vec_json(contact.resolved_velocity) +
                ",\"resolved_angular_velocity\":" + vec_json(contact.resolved_angular_velocity) +
                ",\"max_kinetic_energy_joules\":" + compact_number(contact.max_kinetic_energy_joules) +
                ",\"has_resolved_state\":" + (contact.has_resolved_state ? "true" : "false") + '}';
    };
    std::string scene_objects = "[";
    for (std::size_t index = 0; index < checkpoint.scene_objects.size(); ++index) {
        if (index != 0) {
            scene_objects += ',';
        }
        const ReplaySceneObjectState &object = checkpoint.scene_objects[index];
        scene_objects += "{\"name\":\"" + escape_json_string(object.name) +
                "\",\"asset_id\":\"" + escape_json_string(object.asset_id) +
                "\",\"position\":" + vec_json(object.position) +
                ",\"orientation\":" + quat_json(object.orientation) + '}';
    }
    scene_objects += ']';
    return "{\"timestamp_us\":" + std::to_string(checkpoint.timestamp_us) +
            ",\"upper\":" + rigid_body_state_json(checkpoint.state.upper) +
            ",\"lower\":" + rigid_body_state_json(checkpoint.state.lower) +
            ",\"controllers\":[" + controller_state_json(checkpoint.controllers[0]) + ',' + controller_state_json(checkpoint.controllers[1]) +
            "],\"clocks\":[" + clock_json(checkpoint.clocks[0]) + ',' + clock_json(checkpoint.clocks[1]) +
            "],\"first_response_substeps\":[" + trajectory_json(checkpoint.first_response_substeps[0]) + ',' +
            trajectory_json(checkpoint.first_response_substeps[1]) + "],\"collisions\":[" + collision_json(checkpoint.collisions[0]) + ',' +
            collision_json(checkpoint.collisions[1]) + "],\"scene_objects\":" + scene_objects +
            ",\"environment\":" + checkpoint.environment_json + '}';
}

bool parse_checkpoint(const JsonValue &value, ReplayRunCheckpoint &checkpoint) {
    const JsonValue *timestamp = field(value, "timestamp_us");
    const JsonValue *upper = field(value, "upper");
    const JsonValue *lower = field(value, "lower");
    const JsonValue *controllers = field(value, "controllers");
    const JsonValue *clocks = field(value, "clocks");
    const JsonValue *responses = field(value, "first_response_substeps");
    const JsonValue *collisions = field(value, "collisions");
    const JsonValue *scene_objects = field(value, "scene_objects");
    const JsonValue *environment = field(value, "environment");
    if (!(timestamp != nullptr && upper != nullptr && lower != nullptr && controllers != nullptr && clocks != nullptr && responses != nullptr &&
            collisions != nullptr && scene_objects != nullptr && environment != nullptr &&
            controllers->type == JsonValue::Type::Array && controllers->array.size() == checkpoint.controllers.size() &&
            clocks->type == JsonValue::Type::Array && clocks->array.size() == checkpoint.clocks.size() &&
            responses->type == JsonValue::Type::Array && responses->array.size() == checkpoint.first_response_substeps.size() &&
            integer_value(*timestamp, checkpoint.timestamp_us) &&
            parse_rigid_body_state(*upper, checkpoint.state.upper) &&
            parse_rigid_body_state(*lower, checkpoint.state.lower) &&
            parse_controller_state(controllers->array[0], checkpoint.controllers[0]) &&
            parse_controller_state(controllers->array[1], checkpoint.controllers[1]) &&
            parse_clock(clocks->array[0], checkpoint.clocks[0]) && parse_clock(clocks->array[1], checkpoint.clocks[1]) &&
            parse_trajectory(responses->array[0], checkpoint.first_response_substeps[0]) &&
            parse_trajectory(responses->array[1], checkpoint.first_response_substeps[1]))) {
        return false;
    }
    if (collisions->type != JsonValue::Type::Array || collisions->array.size() != checkpoint.collisions.size()) {
        return false;
    }
    for (std::size_t index = 0; index < checkpoint.collisions.size(); ++index) {
            const JsonValue &collision = collisions->array[index];
            std::string authority;
            bool touching = false;
            bool has_resolved_state = false;
            const JsonValue *authority_value = field(collision, "authority");
            const JsonValue *touching_value = field(collision, "touching");
            const JsonValue *normal = field(collision, "normal");
            const JsonValue *impulse = field(collision, "impulse");
            const JsonValue *restitution = field(collision, "restitution");
            const JsonValue *resolved_velocity = field(collision, "resolved_velocity");
            const JsonValue *resolved_angular_velocity = field(collision, "resolved_angular_velocity");
            const JsonValue *max_energy = field(collision, "max_kinetic_energy_joules");
            const JsonValue *has_resolved = field(collision, "has_resolved_state");
            ReplayCollision &parsed = checkpoint.collisions[index];
            if (authority_value == nullptr || touching_value == nullptr || normal == nullptr || impulse == nullptr ||
                    restitution == nullptr || resolved_velocity == nullptr || resolved_angular_velocity == nullptr ||
                    max_energy == nullptr || has_resolved == nullptr || !string_value(*authority_value, authority) ||
                    !parse_authority(authority, parsed.authority) || !bool_value(*touching_value, touching) ||
                    !parse_vec(*normal, parsed.contact.normal) || !parse_vec(*impulse, parsed.contact.impulse) ||
                    !number_value(*restitution, parsed.contact.restitution) ||
                    !parse_vec(*resolved_velocity, parsed.contact.resolved_velocity) ||
                    !parse_vec(*resolved_angular_velocity, parsed.contact.resolved_angular_velocity) ||
                    !number_value(*max_energy, parsed.contact.max_kinetic_energy_joules) ||
                    !bool_value(*has_resolved, has_resolved_state)) {
                return false;
            }
            parsed.contact.touching = touching;
            parsed.contact.has_resolved_state = has_resolved_state;
            if (!valid_collision_contact(parsed.contact)) {
                return false;
            }
    }
    if (scene_objects->type != JsonValue::Type::Array) {
        return false;
    }
    for (const JsonValue &object : scene_objects->array) {
            ReplaySceneObjectState parsed;
            const JsonValue *name = field(object, "name");
            const JsonValue *asset_id = field(object, "asset_id");
            const JsonValue *position = field(object, "position");
            const JsonValue *orientation = field(object, "orientation");
            if (name == nullptr || asset_id == nullptr || position == nullptr || orientation == nullptr ||
                    !string_value(*name, parsed.name) || !string_value(*asset_id, parsed.asset_id) ||
                    !parse_vec(*position, parsed.position) || !parse_quat(*orientation, parsed.orientation)) {
                return false;
            }
            checkpoint.scene_objects.push_back(std::move(parsed));
    }
    if (environment->type != JsonValue::Type::Object) {
        return false;
    }
    checkpoint.environment_json = compact_json(*environment);
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

const char *command_mode_name(ReplayCommandMode value) {
    switch (value) {
    case ReplayCommandMode::Angle:
        return "angle";
    case ReplayCommandMode::Acro:
        return "acro";
    case ReplayCommandMode::AltitudeHold:
        return "altitude_hold";
    case ReplayCommandMode::Actuator:
        return "actuator";
    }
    return "";
}

bool parse_command_mode(const std::string &value, ReplayCommandMode &result) {
    if (value == "angle") {
        result = ReplayCommandMode::Angle;
    } else if (value == "acro") {
        result = ReplayCommandMode::Acro;
    } else if (value == "altitude_hold") {
        result = ReplayCommandMode::AltitudeHold;
    } else if (value == "actuator") {
        result = ReplayCommandMode::Actuator;
    } else {
        return false;
    }
    return true;
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
    case ReplayEventType::Tuning:
        return "tuning";
    case ReplayEventType::QuickAdjustBinding:
        return "quick_adjust_binding";
    }
    return "";
}

bool parse_event_type(const std::string &value, ReplayEventType &result) {
    const std::string names[] = {"command", "async_command", "simulation_time", "collision", "scene_object", "environment", "tuning", "quick_adjust_binding"};
    for (int index = 0; index < 8; ++index) {
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

bool valid_quick_adjust_profile_json(const std::string &profile_json) {
    JsonValue profile;
    JsonParser parser(profile_json);
    if (!parser.parse(profile) || profile.type != JsonValue::Type::Object) {
        return false;
    }
    const JsonValue *schema_version = field(profile, "schema_version");
    std::int64_t version = 0;
    const JsonValue *slots = field(profile, "slots");
    if (schema_version == nullptr || slots == nullptr || !signed_integer_value(*schema_version, version) ||
            version != 1 || slots->type != JsonValue::Type::Array || slots->array.size() != 8) {
        return false;
    }
    return std::all_of(slots->array.begin(), slots->array.end(), [](const JsonValue &slot) {
        return slot.type == JsonValue::Type::Null || slot.type == JsonValue::Type::Object;
    });
}

ReplayRunResult failed_run(const ReplayDiagnostic &diagnostic) {
    return {false, diagnostic, {}, {}, 0, {}, {}, {}, {}};
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
    if (session.events.empty() || session.events.front().type != ReplayEventType::Environment ||
            session.events.front().timestamp_us != 0) {
        return invalid(ReplayDiagnosticCode::Corrupt, "replay v3 requires captured atmosphere metadata at timestamp zero");
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
        if (require_termination && event.type == ReplayEventType::Collision &&
                event.timestamp_us >= session.termination_timestamp_us) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "collision must precede replay termination by a simulation frame");
        }
        const bool requires_vehicle = event.type == ReplayEventType::Command ||
                event.type == ReplayEventType::AsyncCommand || event.type == ReplayEventType::Collision ||
                event.type == ReplayEventType::Tuning;
        if (requires_vehicle && event.vehicle_name.empty()) {
            return invalid(ReplayDiagnosticCode::InvalidIdentity, "vehicle identity is required for replay event");
        }
        if (!event.vehicle_name.empty() && std::find(names.begin(), names.end(), event.vehicle_name) == names.end()) {
            return invalid(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + event.vehicle_name);
        }
        if (event.type == ReplayEventType::Command && !valid_replay_command(event.command)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay command is outside the live input domain");
        }
        if (event.type == ReplayEventType::Command && event.command_mode == ReplayCommandMode::Acro &&
                !valid_replay_acro_command(event.acro_command)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay acro command is outside the live input domain");
        }
        if (event.type == ReplayEventType::Command &&
                (!std::isfinite(event.measured_altitude_m) ||
                 (event.command_mode == ReplayCommandMode::Actuator &&
                  std::any_of(event.actuator_commands.begin(), event.actuator_commands.end(), [](double value) {
                      return !std::isfinite(value) || value < 0.0 || value > 1.0;
                  })))) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay command contains invalid actuator or altitude data");
        }
        if (event.type == ReplayEventType::Collision &&
                (event.collision.authority != ReplayControllerAuthority::FlightCore &&
                 event.collision.authority != ReplayControllerAuthority::Jolt)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay collision authority is invalid");
        }
        if (event.type == ReplayEventType::Collision && !valid_collision_contact(event.collision.contact)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay collision contact is outside the live domain");
        }
        if (event.type == ReplayEventType::Collision && event.collision.contact.touching &&
                event.collision.authority != ReplayControllerAuthority::Jolt) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "touching replay collision must use jolt authority");
        }
        if (event.type == ReplayEventType::AsyncCommand && (event.command_id.empty() || event.command_method.empty())) {
            return invalid(ReplayDiagnosticCode::InvalidLifecycle, "async replay command id and method are required");
        }
        if (event.type == ReplayEventType::SimulationTime &&
                ((!std::isfinite(event.simulation_value)) ||
                 (event.simulation_operation == ReplaySimulationOperation::StepFrames &&
                        (event.simulation_value < 0.0 || std::floor(event.simulation_value) != event.simulation_value || event.simulation_value > 1000000.0)) ||
                 (event.simulation_operation == ReplaySimulationOperation::StepSeconds &&
                        (event.simulation_value < 0.0 || event.simulation_value > 1000000.0)))) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "invalid replay simulation step value");
        }
        if (event.type == ReplayEventType::Environment) {
            WindConfig wind_config;
            double air_density = 0.0;
            if (!parse_environment_config(event.environment_json, wind_config, air_density)) {
                return invalid(ReplayDiagnosticCode::Corrupt, "replay v4 atmosphere metadata is incomplete");
            }
        }
        if (event.type == ReplayEventType::Tuning &&
                (event.tuning_parameter.empty() || !std::isfinite(event.tuning_requested_value) ||
                 !std::isfinite(event.tuning_committed_value) ||
                 (event.tuning_source != "panel" && event.tuning_source != "quick_adjust" && event.tuning_source != "mixed") ||
                 event.tuning_quick_adjust_slot < -1 || event.tuning_quick_adjust_slot >= 8)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "invalid replay tuning input");
        }
        if (event.type == ReplayEventType::QuickAdjustBinding &&
                !event.vehicle_name.empty()) {
            return invalid(ReplayDiagnosticCode::InvalidIdentity, "Quick Adjust binding must be session-level");
        }
        if (event.type == ReplayEventType::QuickAdjustBinding &&
                !valid_quick_adjust_profile_json(event.quick_adjust_profile_json)) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "invalid Quick Adjust binding profile");
        }
    }
    std::uint64_t previous_checkpoint_timestamp_us = 0;
    bool has_previous_checkpoint = false;
    for (const ReplayRunCheckpoint &checkpoint : session.checkpoints) {
        if (has_previous_checkpoint && checkpoint.timestamp_us < previous_checkpoint_timestamp_us) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay checkpoints must be monotonic");
        }
        if (require_termination && checkpoint.timestamp_us > session.termination_timestamp_us) {
            return invalid(ReplayDiagnosticCode::InvalidSession, "replay checkpoint occurs after termination");
        }
        const RigidBodyState *states[] = {&checkpoint.state.upper, &checkpoint.state.lower};
        for (const RigidBodyState *state : states) {
            if (!finite_vec(state->position) || !finite_quat(state->orientation) ||
                    !finite_vec(state->velocity) || !finite_vec(state->angular_velocity)) {
                return invalid(ReplayDiagnosticCode::InvalidSession, "replay checkpoint contains non-finite state");
            }
        }
        for (const ReplayCollision &collision : checkpoint.collisions) {
            if (!valid_collision_contact(collision.contact)) {
                return invalid(ReplayDiagnosticCode::InvalidSession, "replay checkpoint collision contact is outside the live domain");
            }
        }
        previous_checkpoint_timestamp_us = checkpoint.timestamp_us;
        has_previous_checkpoint = true;
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
            ",\"yaw_rate_degrees_per_second\":" + compact_number(command.yaw_rate_degrees_per_second) +
            ",\"vertical_velocity_mps\":" + compact_number(command.vertical_velocity_mps) +
            ",\"heading_hold_enabled\":" + std::string(command.heading_hold_enabled ? "true" : "false") +
            ",\"position_hold_enabled\":" + std::string(command.position_hold_enabled ? "true" : "false") + "}";
}

std::string acro_command_json(const AcroCommand &command) {
    return "{\"throttle\":" + compact_number(command.throttle) +
            ",\"roll_stick\":" + compact_number(command.roll_stick) +
            ",\"pitch_stick\":" + compact_number(command.pitch_stick) +
            ",\"yaw_stick\":" + compact_number(command.yaw_stick) +
            ",\"rc_rate\":" + compact_number(command.rates.rc_rate) +
            ",\"super_rate\":" + compact_number(command.rates.super_rate) +
            ",\"expo\":" + compact_number(command.rates.expo) + "}";
}

std::string actuator_command_json(const std::array<double, 4> &commands) {
    return "[" + compact_number(commands[0]) + "," + compact_number(commands[1]) + "," +
            compact_number(commands[2]) + "," + compact_number(commands[3]) + "]";
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
                "\",\"mode\":\"" + std::string(command_mode_name(event.command_mode)) +
                "\",\"command\":" + command_json(event.command) +
                ",\"measured_altitude_m\":" + compact_number(event.measured_altitude_m);
        if (event.command_mode == ReplayCommandMode::Acro) {
            result += ",\"acro\":" + acro_command_json(event.acro_command);
        } else if (event.command_mode == ReplayCommandMode::Actuator) {
            result += ",\"actuators\":" + actuator_command_json(event.actuator_commands);
        }
        break;
    case ReplayEventType::AsyncCommand:
        result += ",\"command_id\":\"" + escape_json_string(event.command_id) +
                "\",\"method\":\"" + escape_json_string(event.command_method) +
                "\",\"lifecycle\":\"" + lifecycle_name(event.command_lifecycle) + "\"";
        break;
    case ReplayEventType::SimulationTime:
        result += ",\"operation\":\"" + std::string(simulation_operation_name(event.simulation_operation)) +
                "\",\"value\":" + compact_number(event.simulation_value);
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
    case ReplayEventType::Tuning:
        result += ",\"request_seq\":" + std::to_string(event.tuning_request_seq) +
                ",\"commit_id\":" + std::to_string(event.tuning_commit_id) +
                ",\"parameter\":\"" + escape_json_string(event.tuning_parameter) +
                "\",\"requested_value\":" + compact_number(event.tuning_requested_value) +
                ",\"committed_value\":" + compact_number(event.tuning_committed_value) +
                ",\"clamped\":" + std::string(event.tuning_clamped ? "true" : "false") +
                ",\"source\":\"" + escape_json_string(event.tuning_source) + "\"";
        if (event.tuning_quick_adjust_slot >= 0) {
            result += ",\"quick_adjust_slot\":" + std::to_string(event.tuning_quick_adjust_slot);
        }
        break;
    case ReplayEventType::QuickAdjustBinding:
        result += ",\"profile\":" + event.quick_adjust_profile_json;
        break;
    }
    return result + '}';
}

bool parse_command(const JsonValue &value, FlightCommand &command) {
    const JsonValue *throttle = field(value, "throttle");
    const JsonValue *roll = field(value, "roll_degrees");
    const JsonValue *pitch = field(value, "pitch_degrees");
    const JsonValue *yaw = field(value, "yaw_rate_degrees_per_second");
    if (throttle == nullptr || roll == nullptr || pitch == nullptr || yaw == nullptr ||
            !number_value(*throttle, command.throttle) || !number_value(*roll, command.roll_degrees) ||
            !number_value(*pitch, command.pitch_degrees) || !number_value(*yaw, command.yaw_rate_degrees_per_second)) {
        return false;
    }
    const JsonValue *vertical_velocity = field(value, "vertical_velocity_mps");
    const JsonValue *heading_hold = field(value, "heading_hold_enabled");
    const JsonValue *position_hold = field(value, "position_hold_enabled");
    return (vertical_velocity == nullptr || number_value(*vertical_velocity, command.vertical_velocity_mps)) &&
            (heading_hold == nullptr || bool_value(*heading_hold, command.heading_hold_enabled)) &&
            (position_hold == nullptr || bool_value(*position_hold, command.position_hold_enabled));
}

bool parse_acro_command(const JsonValue &value, AcroCommand &command) {
    const JsonValue *throttle = field(value, "throttle");
    const JsonValue *roll = field(value, "roll_stick");
    const JsonValue *pitch = field(value, "pitch_stick");
    const JsonValue *yaw = field(value, "yaw_stick");
    const JsonValue *rc_rate = field(value, "rc_rate");
    const JsonValue *super_rate = field(value, "super_rate");
    const JsonValue *expo = field(value, "expo");
    return throttle != nullptr && roll != nullptr && pitch != nullptr && yaw != nullptr &&
            rc_rate != nullptr && super_rate != nullptr && expo != nullptr &&
            number_value(*throttle, command.throttle) && number_value(*roll, command.roll_stick) &&
            number_value(*pitch, command.pitch_stick) && number_value(*yaw, command.yaw_stick) &&
            number_value(*rc_rate, command.rates.rc_rate) && number_value(*super_rate, command.rates.super_rate) &&
            number_value(*expo, command.rates.expo);
}

bool parse_actuator_command(const JsonValue &value, std::array<double, 4> &commands) {
    if (value.type != JsonValue::Type::Array || value.array.size() != commands.size()) {
        return false;
    }
    for (std::size_t index = 0; index < commands.size(); ++index) {
        if (!number_value(value.array[index], commands[index]) || commands[index] < 0.0 || commands[index] > 1.0) {
            return false;
        }
    }
    return true;
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
    if (event.type == ReplayEventType::QuickAdjustBinding && vehicle != nullptr) {
        return false;
    }
    switch (event.type) {
    case ReplayEventType::Command: {
        std::string authority;
        const JsonValue *authority_value = field(value, "authority");
        const JsonValue *mode_value = field(value, "mode");
        const JsonValue *command = field(value, "command");
        std::string mode = "angle";
        if (mode_value != nullptr && !string_value(*mode_value, mode)) {
            return false;
        }
        if (authority_value == nullptr || command == nullptr || !string_value(*authority_value, authority) ||
                !parse_authority(authority, event.controller_authority) || !parse_command(*command, event.command) ||
                !parse_command_mode(mode, event.command_mode)) {
            return false;
        }
        if (event.command_mode == ReplayCommandMode::Acro) {
            const JsonValue *acro = field(value, "acro");
            if (acro == nullptr || !parse_acro_command(*acro, event.acro_command)) {
                return false;
            }
        } else if (event.command_mode == ReplayCommandMode::Actuator) {
            const JsonValue *actuators = field(value, "actuators");
            if (actuators == nullptr || !parse_actuator_command(*actuators, event.actuator_commands)) {
                return false;
            }
        }
        const JsonValue *measured_altitude = field(value, "measured_altitude_m");
        if (measured_altitude != nullptr && !number_value(*measured_altitude, event.measured_altitude_m)) {
            return false;
        }
        return true;
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
                number_value(*simulation_value, event.simulation_value);
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
    case ReplayEventType::Tuning: {
        const JsonValue *request_seq = field(value, "request_seq");
        const JsonValue *commit_id = field(value, "commit_id");
        const JsonValue *parameter = field(value, "parameter");
        const JsonValue *requested = field(value, "requested_value");
        const JsonValue *committed = field(value, "committed_value");
        const JsonValue *clamped = field(value, "clamped");
        const JsonValue *source = field(value, "source");
        const JsonValue *quick_adjust_slot = field(value, "quick_adjust_slot");
        std::int64_t parsed_slot = -1;
        return request_seq != nullptr && commit_id != nullptr && parameter != nullptr && requested != nullptr &&
                committed != nullptr && clamped != nullptr && source != nullptr && integer_value(*request_seq, event.tuning_request_seq) &&
                integer_value(*commit_id, event.tuning_commit_id) && string_value(*parameter, event.tuning_parameter) &&
                number_value(*requested, event.tuning_requested_value) && number_value(*committed, event.tuning_committed_value) &&
                bool_value(*clamped, event.tuning_clamped) &&
                string_value(*source, event.tuning_source) &&
                (quick_adjust_slot == nullptr || signed_integer_value(*quick_adjust_slot, parsed_slot)) &&
                (event.tuning_quick_adjust_slot = quick_adjust_slot == nullptr ? -1 : static_cast<std::int32_t>(parsed_slot), true);
    }
    case ReplayEventType::QuickAdjustBinding: {
        const JsonValue *profile = field(value, "profile");
        if (profile == nullptr || profile->type != JsonValue::Type::Object) {
            return false;
        }
        event.quick_adjust_profile_json = compact_json(*profile);
        return valid_quick_adjust_profile_json(event.quick_adjust_profile_json);
    }
    }
    return false;
}

bool same_or_close(double expected, double actual, double tolerance) {
    if (tolerance == 0.0) {
        std::uint64_t expected_bits = 0;
        std::uint64_t actual_bits = 0;
        static_assert(sizeof(expected_bits) == sizeof(expected));
        std::memcpy(&expected_bits, &expected, sizeof(expected_bits));
        std::memcpy(&actual_bits, &actual, sizeof(actual_bits));
        return expected_bits == actual_bits;
    }
    return std::isfinite(expected) && std::isfinite(actual) && std::abs(expected - actual) <= tolerance;
}

const char *rigid_body_difference(const RigidBodyState &expected, const RigidBodyState &actual, double tolerance) {
    const double expected_values[] = {
            expected.position.x, expected.position.y, expected.position.z,
            expected.orientation.x, expected.orientation.y, expected.orientation.z, expected.orientation.w,
            expected.velocity.x, expected.velocity.y, expected.velocity.z,
            expected.angular_velocity.x, expected.angular_velocity.y, expected.angular_velocity.z,
            expected.propwash_disturbance_rad_s2.x, expected.propwash_disturbance_rad_s2.y, expected.propwash_disturbance_rad_s2.z,
            expected.motor_thrust_newtons[0], expected.motor_thrust_newtons[1], expected.motor_thrust_newtons[2], expected.motor_thrust_newtons[3],
    };
    const double actual_values[] = {
            actual.position.x, actual.position.y, actual.position.z,
            actual.orientation.x, actual.orientation.y, actual.orientation.z, actual.orientation.w,
            actual.velocity.x, actual.velocity.y, actual.velocity.z,
            actual.angular_velocity.x, actual.angular_velocity.y, actual.angular_velocity.z,
            actual.propwash_disturbance_rad_s2.x, actual.propwash_disturbance_rad_s2.y, actual.propwash_disturbance_rad_s2.z,
            actual.motor_thrust_newtons[0], actual.motor_thrust_newtons[1], actual.motor_thrust_newtons[2], actual.motor_thrust_newtons[3],
    };
    const char *fields[] = {
            "position.x", "position.y", "position.z", "orientation.x", "orientation.y", "orientation.z", "orientation.w",
            "velocity.x", "velocity.y", "velocity.z", "angular_velocity.x", "angular_velocity.y", "angular_velocity.z",
            "propwash.x", "propwash.y", "propwash.z", "motor[0]", "motor[1]", "motor[2]", "motor[3]",
    };
    for (std::size_t index = 0; index < sizeof(expected_values) / sizeof(expected_values[0]); ++index) {
        if (!same_or_close(expected_values[index], actual_values[index], tolerance)) {
            return fields[index];
        }
    }
    return nullptr;
}

const char *trajectory_propwash_difference(
        const TrajectorySample &expected,
        const TrajectorySample &actual,
        double tolerance) {
    const double expected_values[] = {
            expected.propwash_disturbance_rad_s2.x,
            expected.propwash_disturbance_rad_s2.y,
            expected.propwash_disturbance_rad_s2.z,
    };
    const double actual_values[] = {
            actual.propwash_disturbance_rad_s2.x,
            actual.propwash_disturbance_rad_s2.y,
            actual.propwash_disturbance_rad_s2.z,
    };
    const char *axes[] = {"x", "y", "z"};
    for (std::size_t axis = 0; axis < 3; ++axis) {
        if (!same_or_close(expected_values[axis], actual_values[axis], tolerance)) {
            return axes[axis];
        }
    }
    return nullptr;
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
    if (session_.vehicles.size() >= checkpoint_collisions_.size()) {
        return fail(ReplayDiagnosticCode::InvalidSession, "complete replay supports exactly two vehicles");
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
    if (controller_authority != ReplayControllerAuthority::FlightCore &&
            controller_authority != ReplayControllerAuthority::Jolt) {
        return fail(ReplayDiagnosticCode::InvalidSession, "collision replay authority must be flight_core or jolt");
    }
    if (!valid_replay_command(command)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay command is outside the live input domain");
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

bool ReplaySessionRecorder::record_mode_command(
        std::uint64_t timestamp_us,
        const std::string &vehicle_name,
        ReplayCommandMode command_mode,
        const FlightCommand &command,
        const AcroCommand &acro_command,
        ReplayControllerAuthority controller_authority,
        double measured_altitude_m) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (command_mode != ReplayCommandMode::Angle && command_mode != ReplayCommandMode::Acro &&
            command_mode != ReplayCommandMode::AltitudeHold && command_mode != ReplayCommandMode::Actuator) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay command mode is invalid");
    }
    if (!valid_replay_command(command) || !std::isfinite(measured_altitude_m) ||
            (command_mode == ReplayCommandMode::Acro && !valid_replay_acro_command(acro_command))) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay command is outside the live input domain");
    }
    if (!has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + vehicle_name);
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Command;
    event.vehicle_name = vehicle_name;
    event.controller_authority = controller_authority;
    event.command_mode = command_mode;
    event.command = command;
    event.acro_command = acro_command;
    event.measured_altitude_m = measured_altitude_m;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_actuator_command(
        std::uint64_t timestamp_us,
        const std::string &vehicle_name,
        const MotorCommands &commands,
        ReplayControllerAuthority controller_authority) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (controller_authority != ReplayControllerAuthority::Px4External || !has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "PX4 replay actuator authority is invalid");
    }
    for (double value : commands.normalized) {
        if (!std::isfinite(value) || value < 0.0 || value > 1.0) {
            return fail(ReplayDiagnosticCode::InvalidSession, "replay actuator command is invalid");
        }
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Command;
    event.vehicle_name = vehicle_name;
    event.controller_authority = controller_authority;
    event.command_mode = ReplayCommandMode::Actuator;
    event.actuator_commands = commands.normalized;
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
        double value) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!std::isfinite(value) || (operation == ReplaySimulationOperation::StepFrames &&
            (value < 0.0 || std::floor(value) != value || value > 1000000.0)) ||
            (operation == ReplaySimulationOperation::StepSeconds && (value < 0.0 || value > 1000000.0))) {
        return fail(ReplayDiagnosticCode::InvalidSession, "simulation step value must not be negative");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::SimulationTime;
    event.simulation_operation = operation;
    event.simulation_value = value;
    session_.events.push_back(std::move(event));
    if (operation == ReplaySimulationOperation::Reset || operation == ReplaySimulationOperation::Respawn) {
        checkpoint_collisions_ = {};
        checkpoint_scene_objects_.clear();
    }
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
    if (!valid_collision_contact(contact)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "collision replay contact is outside the live domain");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Collision;
    event.vehicle_name = vehicle_name;
    event.collision = {controller_authority, contact};
    const auto vehicle = std::find_if(session_.vehicles.begin(), session_.vehicles.end(), [&](const ReplayVehicleConfig &entry) {
        return entry.name == vehicle_name;
    });
    checkpoint_collisions_[static_cast<std::size_t>(std::distance(session_.vehicles.begin(), vehicle))] = event.collision;
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
    if (operation == ReplaySceneObjectOperation::Reset) {
        checkpoint_scene_objects_.clear();
    } else {
        const auto existing = std::find_if(checkpoint_scene_objects_.begin(), checkpoint_scene_objects_.end(), [&](const ReplaySceneObjectState &object) {
            return object.name == event.object_name;
        });
        if (operation == ReplaySceneObjectOperation::Destroy) {
            if (existing != checkpoint_scene_objects_.end()) {
                checkpoint_scene_objects_.erase(existing);
            }
        } else if (existing == checkpoint_scene_objects_.end()) {
            checkpoint_scene_objects_.push_back({event.object_name, event.object_asset_id, event.object_position, event.object_orientation});
        } else {
            existing->asset_id = event.object_asset_id;
            existing->position = event.object_position;
            existing->orientation = event.object_orientation;
        }
    }
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
    WindConfig wind_config;
    double air_density = 0.0;
    if (!parse_environment_config(environment_json, wind_config, air_density)) {
        return fail(ReplayDiagnosticCode::Corrupt, "replay v3 atmosphere metadata is incomplete");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Environment;
    environment_json_ = compact_json(parsed);
    event.environment_json = environment_json_;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_quick_adjust_binding(
        std::uint64_t timestamp_us,
        std::string profile_json) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    JsonValue parsed;
    JsonParser parser(profile_json);
    if (!parser.parse(parsed) || !valid_quick_adjust_profile_json(profile_json)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "invalid Quick Adjust binding profile");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::QuickAdjustBinding;
    event.quick_adjust_profile_json = compact_json(parsed);
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_tuning(
        std::uint64_t timestamp_us,
        const std::string &vehicle_name,
        std::uint64_t request_seq,
        std::uint64_t commit_id,
        const std::string &parameter,
        double requested_value,
        double committed_value,
        bool clamped,
        const std::string &source,
        std::int32_t quick_adjust_slot) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!has_vehicle(vehicle_name)) {
        return fail(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + vehicle_name);
    }
    if (parameter.empty() || !std::isfinite(requested_value) || !std::isfinite(committed_value) ||
            (source != "panel" && source != "quick_adjust" && source != "mixed") ||
            quick_adjust_slot < -1 || quick_adjust_slot >= 8) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay tuning input is invalid");
    }
    ReplayEvent event;
    event.timestamp_us = timestamp_us;
    event.type = ReplayEventType::Tuning;
    event.vehicle_name = vehicle_name;
    event.tuning_request_seq = request_seq;
    event.tuning_commit_id = commit_id;
    event.tuning_parameter = parameter;
    event.tuning_requested_value = requested_value;
    event.tuning_committed_value = committed_value;
    event.tuning_clamped = clamped;
    event.tuning_source = source;
    event.tuning_quick_adjust_slot = quick_adjust_slot;
    session_.events.push_back(std::move(event));
    diagnostic_ = {};
    return true;
}

bool ReplaySessionRecorder::record_checkpoint(std::uint64_t timestamp_us, const DualAircraftState &state) {
    ReplayRunCheckpoint checkpoint;
    checkpoint.state = state;
    return record_checkpoint(timestamp_us, std::move(checkpoint));
}

bool ReplaySessionRecorder::record_checkpoint(std::uint64_t timestamp_us, ReplayRunCheckpoint checkpoint) {
    if (finished_) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay session is already finished");
    }
    if (!finite_vec(checkpoint.state.upper.position) || !finite_quat(checkpoint.state.upper.orientation) ||
            !finite_vec(checkpoint.state.upper.velocity) || !finite_vec(checkpoint.state.upper.angular_velocity) ||
            !finite_vec(checkpoint.state.lower.position) || !finite_quat(checkpoint.state.lower.orientation) ||
            !finite_vec(checkpoint.state.lower.velocity) || !finite_vec(checkpoint.state.lower.angular_velocity)) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay checkpoint state must be finite");
    }
    if (!session_.checkpoints.empty() && timestamp_us < session_.checkpoints.back().timestamp_us) {
        return fail(ReplayDiagnosticCode::InvalidSession, "replay checkpoints must be monotonic");
    }
    checkpoint.timestamp_us = timestamp_us;
    checkpoint.collisions = checkpoint_collisions_;
    checkpoint.scene_objects = checkpoint_scene_objects_;
    checkpoint.environment_json = environment_json_;
    session_.checkpoints.push_back(std::move(checkpoint));
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
    result += "],\"checkpoints\":[";
    for (std::size_t index = 0; index < session.checkpoints.size(); ++index) {
        if (index != 0) {
            result += ',';
        }
        result += checkpoint_json(session.checkpoints[index]);
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
    const JsonValue *checkpoints = field(root, "checkpoints");
    const JsonValue *termination = field(root, "termination");
    std::int64_t schema_number = 0;
    if (schema == nullptr || !signed_integer_value(*schema, schema_number) ||
            schema_number < std::numeric_limits<std::int32_t>::min() ||
            schema_number > std::numeric_limits<std::int32_t>::max()) {
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
    if (seed == nullptr || !integer_value(*seed, session.seed) || vehicles == nullptr ||
            vehicles->type != JsonValue::Type::Array || vehicles->array.size() != 2) {
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
    if (checkpoints != nullptr) {
        if (checkpoints->type != JsonValue::Type::Array) {
            return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay checkpoints must be an array")};
        }
        for (const JsonValue &value : checkpoints->array) {
            ReplayRunCheckpoint checkpoint;
            if (!parse_checkpoint(value, checkpoint)) {
                return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "invalid replay checkpoint")};
            }
            const ReplayEvent *environment = nullptr;
            for (const ReplayEvent &event : session.events) {
                if (event.type == ReplayEventType::Environment && event.timestamp_us <= checkpoint.timestamp_us &&
                        (environment == nullptr || event.timestamp_us >= environment->timestamp_us)) {
                    environment = &event;
                }
            }
            if (environment == nullptr) {
                return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay checkpoint has no atmosphere context")};
            }
            if (checkpoint.environment_json != environment->environment_json) {
                return {false, {}, invalid(ReplayDiagnosticCode::Corrupt, "replay checkpoint atmosphere disagrees with event context")};
            }
            session.checkpoints.push_back(std::move(checkpoint));
        }
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
        const DualAircraftConfig &config,
        const std::string &expected_settings_manifest_hash,
        const std::array<std::string, 2> &expected_vehicle_config_hashes,
        bool require_complete_vehicle_manifest) {
    const ReplayDiagnostic validation = validate_session(session, true);
    if (!validation.ok()) {
        return failed_run(validation);
    }
    if (expected_settings_manifest_hash.empty() || session.settings_manifest_hash != expected_settings_manifest_hash ||
            expected_vehicle_config_hashes[0].empty() || expected_vehicle_config_hashes[1].empty()) {
        return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "replay compatibility manifests are required and must match"));
    }
    if (config.upper.physics_hz <= 0 || config.upper.substep_hz <= 0 ||
            config.lower.physics_hz != config.upper.physics_hz ||
            config.lower.substep_hz != config.upper.substep_hz ||
            config.upper.mass_kg <= 0.0 || config.lower.mass_kg <= 0.0 ||
            !validate_per_motor_config(config.upper.per_motor) ||
            !validate_per_motor_config(config.lower.per_motor)) {
        return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay runtime configuration is invalid"));
    }
    const SimulationConfig runtime_configs[] = {config.upper, config.lower};
    SimulationConfig active_configs[] = {config.upper, config.lower};
    WindField wind_fields[2];
    wind_fields[0].configure(WindConfig{});
    wind_fields[1].configure(WindConfig{});
    for (std::size_t index = 0; index < 2; ++index) {
        if (!expected_vehicle_config_hashes[index].empty() &&
                session.vehicles[index].config_manifest_hash != expected_vehicle_config_hashes[index]) {
            return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "vehicle config manifest is incompatible"));
        }
        JsonValue parsed;
        JsonParser parser(session.vehicles[index].config_json);
        if (!parser.parse(parsed) || parsed.type != JsonValue::Type::Object) {
            return failed_run(invalid(ReplayDiagnosticCode::MissingVehicleConfig, "vehicle config is not a JSON object"));
        }
        if (require_complete_vehicle_manifest && !json_config_matches(session.vehicles[index].config_json, runtime_configs[index])) {
            return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "complete vehicle config manifest does not match replay runtime"));
        }
        const JsonValue *mass = field(parsed, "mass_kg");
        double recorded_mass = 0.0;
        if (mass == nullptr || !number_value(*mass, recorded_mass) || recorded_mass != runtime_configs[index].mass_kg) {
            return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "vehicle mass does not match replay runtime configuration"));
        }
        const JsonValue *gravity = field(parsed, "gravity_mps2");
        double recorded_gravity = 0.0;
        if (gravity != nullptr && (!number_value(*gravity, recorded_gravity) || recorded_gravity != runtime_configs[index].gravity_mps2)) {
            return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "vehicle gravity does not match replay runtime configuration"));
        }
        const JsonValue *physics_hz = field(parsed, "physics_hz");
        std::int64_t recorded_physics_hz = 0;
        if (physics_hz != nullptr && (!signed_integer_value(*physics_hz, recorded_physics_hz) || recorded_physics_hz != runtime_configs[index].physics_hz)) {
            return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "vehicle physics rate does not match replay runtime configuration"));
        }
        const JsonValue *substep_hz = field(parsed, "substep_hz");
        std::int64_t recorded_substep_hz = 0;
        if (substep_hz != nullptr && (!signed_integer_value(*substep_hz, recorded_substep_hz) || recorded_substep_hz != runtime_configs[index].substep_hz)) {
            return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, "vehicle substep rate does not match replay runtime configuration"));
        }
        struct OptionalManifestField {
            const char *name;
            double expected;
            const char *diagnostic;
        };
        const OptionalManifestField optional_fields[] = {
                {"max_total_thrust_newtons", runtime_configs[index].max_total_thrust_newtons, "vehicle max thrust"},
                {"hover_throttle", runtime_configs[index].hover_throttle, "vehicle hover throttle"},
                {"motor_tau_s", runtime_configs[index].motor_tau_s, "vehicle motor time constant"},
                {"battery_nominal_voltage_v", runtime_configs[index].battery_nominal_voltage_v, "vehicle battery voltage"},
                {"battery_cells", runtime_configs[index].battery_cells, "vehicle battery cell count"},
                {"battery_cell_resistance_ohm", runtime_configs[index].battery_cell_resistance_ohm, "vehicle battery resistance"},
                {"battery_remaining_mah", runtime_configs[index].battery_remaining_mah, "vehicle battery capacity"},
                {"max_total_current_a", runtime_configs[index].max_total_current_a, "vehicle max current"},
                {"max_motor_rpm", runtime_configs[index].max_motor_rpm, "vehicle max motor speed"},
                {"altitude_hold_noise_deadband_m", runtime_configs[index].altitude_hold_noise_deadband_m, "vehicle altitude noise deadband"},
        };
        for (const OptionalManifestField &optional : optional_fields) {
            const JsonValue *value = field(parsed, optional.name);
            double recorded_value = 0.0;
            if (value != nullptr && (!number_value(*value, recorded_value) || recorded_value != optional.expected)) {
                return failed_run(invalid(ReplayDiagnosticCode::IncompatibleManifest, std::string(optional.diagnostic) + " does not match replay runtime configuration"));
            }
        }
    }

    DualAircraftState state{config.upper.initial_state, config.lower.initial_state};
    SimulationClock clocks[2];
    FlightController controllers[2];
    controllers[0].arm(0.0);
    controllers[1].arm(0.0);
    CollisionAuthoritySwitch collision_switches[2];
    FlightCommand commands[2];
    AcroCommand acro_commands[2];
    MotorCommands actuator_commands[2];
    double measured_altitudes[2] = {0.0, 0.0};
    ReplayCommandMode command_modes[2] = {ReplayCommandMode::Angle, ReplayCommandMode::Angle};
    bool vehicle_active[2] = {false, false};
    CollisionContact pending_collisions[2];
    ReplayControllerAuthority pending_collision_authorities[2] = {
            ReplayControllerAuthority::FlightCore, ReplayControllerAuthority::FlightCore};
    ReplayCollision last_collisions[2];
    bool has_pending_collision[2] = {false, false};
    bool paused = false;
    double frame_remainder = 0.0;
    std::vector<ReplaySceneObjectState> scene_objects;
    std::string environment_json;
    std::vector<ReplayRunCheckpoint> checkpoints;
    TrajectorySample first_response_substeps[2];
    bool has_first_response[2] = {false, false};
    const bool has_recorded_checkpoints = !session.checkpoints.empty();
    std::size_t recorded_checkpoint_index = 0;
    std::uint64_t previous_timestamp_us = 0;
    StepStatus replay_step_status = StepStatus::Ok;
    const auto vehicle_index = [&](const std::string &name) {
        return name == session.vehicles[0].name ? 0 : name == session.vehicles[1].name ? 1 : -1;
    };
    const auto checkpoint = [&](std::uint64_t timestamp_us) {
        ReplayRunCheckpoint recorded;
        recorded.timestamp_us = timestamp_us;
        recorded.state = state;
        recorded.controllers = {{controllers[0].control_state(), controllers[1].control_state()}};
        recorded.clocks = {{clocks[0], clocks[1]}};
        recorded.first_response_substeps = {{first_response_substeps[0], first_response_substeps[1]}};
        recorded.collisions = {{last_collisions[0], last_collisions[1]}};
        recorded.scene_objects = scene_objects;
        recorded.environment_json = environment_json;
        checkpoints.push_back(std::move(recorded));
    };
    const auto checkpoint_recorded_at = [&](std::uint64_t timestamp_us) {
        while (recorded_checkpoint_index < session.checkpoints.size() &&
                session.checkpoints[recorded_checkpoint_index].timestamp_us == timestamp_us) {
            checkpoint(timestamp_us);
            ++recorded_checkpoint_index;
        }
    };
    const auto step_vehicle = [&](std::size_t index, RigidBodyState &vehicle_state, SimulationClock &clock,
                                  FlightController &controller, const SimulationConfig &vehicle_config) {
        if (!vehicle_active[index]) {
            return true;
        }
        SimulationConfig frame_config = vehicle_config;
        const double time_seconds = static_cast<double>(clock.total_substeps) /
                static_cast<double>(std::max(1, vehicle_config.substep_hz));
        frame_config.wind_world_mps = wind_fields[index].sample(time_seconds, vehicle_state.position);
        frame_config.wind_turbulence_mps = wind_fields[index].turbulence(time_seconds);
        TrajectorySample frame_sample;
        if (has_pending_collision[index]) {
            CollisionStepResult result;
            if (command_modes[index] == ReplayCommandMode::Actuator) {
                result = collision_switches[index].try_step_per_motor(vehicle_state, clock, frame_config,
                        actuator_commands[index], pending_collisions[index]);
            } else if (command_modes[index] == ReplayCommandMode::Acro) {
                result = collision_switches[index].try_step_acro(vehicle_state, clock, controller, frame_config,
                        acro_commands[index], pending_collisions[index]);
            } else if (command_modes[index] == ReplayCommandMode::AltitudeHold) {
                result = collision_switches[index].try_step_altitude_hold(vehicle_state, clock, controller, frame_config,
                        commands[index], measured_altitudes[index], pending_collisions[index], vehicle_state.orientation);
            } else {
                result = collision_switches[index].try_step(vehicle_state, clock, controller, frame_config,
                        commands[index], pending_collisions[index]);
            }
            has_pending_collision[index] = false;
            if (result.status != StepStatus::Ok) {
                replay_step_status = result.status;
                return false;
            }
            const ReplayControllerAuthority actual_authority = result.authority == PhysicsAuthority::Jolt ?
                    ReplayControllerAuthority::Jolt : ReplayControllerAuthority::FlightCore;
            if (actual_authority != pending_collision_authorities[index]) {
                return false;
            }
            frame_sample = result.sample;
        } else if (command_modes[index] == ReplayCommandMode::Actuator &&
                std::all_of(actuator_commands[index].normalized.begin(), actuator_commands[index].normalized.end(), [](double value) {
                    return std::abs(value) <= 0.05;
                })) {
            return true;
        } else {
            StepResult result;
            if (command_modes[index] == ReplayCommandMode::Actuator) {
                const CollisionStepResult actuator_result = collision_switches[index].try_step_per_motor(
                        vehicle_state, clock, frame_config, actuator_commands[index], {});
                if (actuator_result.status != StepStatus::Ok) {
                    replay_step_status = actuator_result.status;
                    return false;
                }
                frame_sample = actuator_result.sample;
            } else if (command_modes[index] == ReplayCommandMode::Acro) {
                result = controller.try_step_acro_mode(vehicle_state, clock, frame_config, acro_commands[index]);
            } else if (command_modes[index] == ReplayCommandMode::AltitudeHold) {
                result = controller.try_step_altitude_hold_mode(vehicle_state, clock, frame_config, commands[index],
                        measured_altitudes[index], vehicle_state.orientation);
            } else {
                result = controller.try_step_angle_mode(vehicle_state, clock, frame_config, commands[index], vehicle_state.orientation);
            }
            if (command_modes[index] != ReplayCommandMode::Actuator) {
                if (result.status != StepStatus::Ok) {
                    replay_step_status = result.status;
                    return false;
                }
                frame_sample = result.sample;
            }
        }
        const bool response = command_modes[index] == ReplayCommandMode::Actuator ?
                std::any_of(actuator_commands[index].normalized.begin(), actuator_commands[index].normalized.end(), [](double value) {
                    return value != 0.5;
                }) : command_modes[index] == ReplayCommandMode::Acro ?
                (acro_commands[index].throttle != 0.5 || acro_commands[index].roll_stick != 0.0 ||
                 acro_commands[index].pitch_stick != 0.0 || acro_commands[index].yaw_stick != 0.0) :
                (commands[index].throttle != 0.5 || commands[index].roll_degrees != 0.0 ||
                 commands[index].pitch_degrees != 0.0 || commands[index].yaw_rate_degrees_per_second != 0.0);
        if (response && clock.total_substeps > 0 && !has_first_response[index]) {
            first_response_substeps[index] = frame_sample;
            if (frame_sample.first_substeps > 0) {
                first_response_substeps[index].time_seconds = frame_sample.first_substep_time_seconds;
                first_response_substeps[index].state = frame_sample.first_substep_state;
                first_response_substeps[index].substeps = frame_sample.first_substeps;
            }
            has_first_response[index] = true;
        }
        return true;
    };
    const auto replay_step_failure = [&] {
        return failed_run(invalid(ReplayDiagnosticCode::InvalidSession,
                std::string("replay runtime step failed: ") + step_status_code(replay_step_status)));
    };
    const auto step_frame = [&](std::uint64_t timestamp_us) {
        if (!step_vehicle(0, state.upper, clocks[0], controllers[0], active_configs[0]) ||
                !step_vehicle(1, state.lower, clocks[1], controllers[1], active_configs[1])) {
            return false;
        }
        if (!has_recorded_checkpoints) {
            checkpoint(timestamp_us);
        }
        return true;
    };
    const auto step_frames = [&](std::int64_t count, std::uint64_t timestamp_us) {
        for (std::int64_t frame = 0; frame < count; ++frame) {
            if (!step_frame(timestamp_us)) {
                return false;
            }
        }
        return true;
    };
    const auto step_seconds = [&](double seconds, std::uint64_t timestamp_us) {
        const double frames = seconds * static_cast<double>(config.upper.physics_hz);
        if (!std::isfinite(frames) || frames < 0.0 || frames > 1000000.0) {
            return false;
        }
        if (!step_frames(static_cast<std::int64_t>(std::ceil(frames)), timestamp_us)) {
            return false;
        }
        frame_remainder = 0.0;
        return true;
    };
    const auto advance_us = [&](std::uint64_t duration_us, std::uint64_t timestamp_us) {
        std::uint64_t cursor_us = timestamp_us - duration_us;
        const auto advance_segment = [&](std::uint64_t segment_us, std::uint64_t segment_timestamp_us) {
            const long double frames = static_cast<long double>(frame_remainder) +
                    static_cast<long double>(segment_us) * static_cast<long double>(config.upper.physics_hz) / 1000000.0L;
            if (!std::isfinite(static_cast<double>(frames)) || frames < 0.0L || frames > 1000000.0L) {
                return false;
            }
            const auto frame_count = static_cast<std::int64_t>(std::floor(frames));
            frame_remainder = frames - static_cast<double>(frame_count);
            return step_frames(frame_count, segment_timestamp_us);
        };
        while (has_recorded_checkpoints && recorded_checkpoint_index < session.checkpoints.size()) {
            const std::uint64_t checkpoint_timestamp_us = session.checkpoints[recorded_checkpoint_index].timestamp_us;
            if (checkpoint_timestamp_us <= cursor_us || checkpoint_timestamp_us >= timestamp_us) {
                break;
            }
            if (!advance_segment(checkpoint_timestamp_us - cursor_us, checkpoint_timestamp_us)) {
                return false;
            }
            checkpoint_recorded_at(checkpoint_timestamp_us);
            cursor_us = checkpoint_timestamp_us;
        }
        if (!advance_segment(timestamp_us - cursor_us, timestamp_us)) {
            return false;
        }
        return true;
    };

    std::size_t event_index = 0;
    while (event_index < session.events.size()) {
        const std::uint64_t timestamp_us = session.events[event_index].timestamp_us;
        std::size_t group_end = event_index;
        while (group_end < session.events.size() && session.events[group_end].timestamp_us == timestamp_us) {
            ++group_end;
        }
        if (!paused && timestamp_us >= previous_timestamp_us &&
                !advance_us(timestamp_us - previous_timestamp_us, timestamp_us)) {
            if (replay_step_status != StepStatus::Ok) {
                return replay_step_failure();
            }
            return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay timeline interval exceeds runtime frame limit"));
        }
        previous_timestamp_us = timestamp_us;
        for (std::size_t index = event_index; index < group_end; ++index) {
            const ReplayEvent &event = session.events[index];
            if (event.type == ReplayEventType::Command) {
                const int vehicle = vehicle_index(event.vehicle_name);
                if (vehicle < 0) {
                    return failed_run(invalid(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + event.vehicle_name));
                }
                if (event.controller_authority != session.vehicles[vehicle].controller_authority) {
                    return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay command authority does not match vehicle authority"));
                }
                commands[vehicle] = event.command;
                command_modes[vehicle] = event.command_mode;
                acro_commands[vehicle] = event.acro_command;
                actuator_commands[vehicle].normalized = event.actuator_commands;
                measured_altitudes[vehicle] = event.measured_altitude_m;
                vehicle_active[vehicle] = true;
                if (event.controller_authority != ReplayControllerAuthority::FlightCore &&
                        !(event.controller_authority == ReplayControllerAuthority::Px4External &&
                          event.command_mode == ReplayCommandMode::Actuator)) {
                    return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay command authority requires matching command data"));
                }
            } else if (event.type == ReplayEventType::Collision) {
                const int vehicle = vehicle_index(event.vehicle_name);
                if (vehicle < 0) {
                    return failed_run(invalid(ReplayDiagnosticCode::UnknownVehicle, "unknown replay vehicle: " + event.vehicle_name));
                }
                if (has_pending_collision[vehicle]) {
                    return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "multiple replay collisions share one simulation frame"));
                }
                pending_collisions[vehicle] = event.collision.contact;
                pending_collision_authorities[vehicle] = event.collision.authority;
                last_collisions[vehicle] = event.collision;
                has_pending_collision[vehicle] = true;
            }
        }
        for (std::size_t index = event_index; index < group_end; ++index) {
        const ReplayEvent &event = session.events[index];
        switch (event.type) {
        case ReplayEventType::Command: {
            break;
        }
        case ReplayEventType::AsyncCommand:
            break;
        case ReplayEventType::QuickAdjustBinding:
            break;
        case ReplayEventType::Tuning: {
            const int vehicle = vehicle_index(event.vehicle_name);
            bool applied = false;
            if (vehicle >= 0 && event.tuning_parameter == kSimpleFlightRatePParameter) {
                applied = controllers[vehicle].set_rate_p(event.tuning_committed_value);
            } else if (vehicle >= 0 && event.tuning_parameter == kSimpleFlightAnglePParameter) {
                applied = controllers[vehicle].set_angle_p(event.tuning_committed_value);
            } else if (vehicle >= 0 && event.tuning_parameter == kSimpleFlightRateIParameter) {
                applied = controllers[vehicle].set_rate_i(event.tuning_committed_value);
            } else if (vehicle >= 0 && event.tuning_parameter == kSimpleFlightRateDParameter) {
                applied = controllers[vehicle].set_rate_d(event.tuning_committed_value);
            }
            if (!applied) {
                return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay tuning input is unsupported"));
            }
            break;
        }
        case ReplayEventType::SceneObject: {
            if (event.object_operation == ReplaySceneObjectOperation::Reset) {
                scene_objects.clear();
                break;
            }
            const auto existing = std::find_if(scene_objects.begin(), scene_objects.end(), [&](const ReplaySceneObjectState &object) {
                return object.name == event.object_name;
            });
            if (event.object_operation == ReplaySceneObjectOperation::Destroy) {
                if (existing != scene_objects.end()) {
                    scene_objects.erase(existing);
                }
            } else if (existing == scene_objects.end()) {
                scene_objects.push_back({event.object_name, event.object_asset_id, event.object_position, event.object_orientation});
            } else {
                existing->asset_id = event.object_asset_id;
                existing->position = event.object_position;
                existing->orientation = event.object_orientation;
            }
            break;
        }
        case ReplayEventType::Environment:
            environment_json = event.environment_json;
            if (!apply_environment_config(environment_json, active_configs, wind_fields)) {
                return failed_run(invalid(ReplayDiagnosticCode::Corrupt, "replay environment state is unsupported"));
            }
            break;
        case ReplayEventType::Collision: {
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
                if (!step_frames(static_cast<std::int64_t>(event.simulation_value), event.timestamp_us)) {
                    if (replay_step_status != StepStatus::Ok) {
                        return replay_step_failure();
                    }
                    return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay collision authority diverged"));
                }
                break;
            case ReplaySimulationOperation::StepSeconds:
                if (!step_seconds(event.simulation_value, event.timestamp_us)) {
                    if (replay_step_status != StepStatus::Ok) {
                        return replay_step_failure();
                    }
                    return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay step seconds exceeds runtime frame limit"));
                }
                break;
            case ReplaySimulationOperation::Reset:
                state = {};
                active_configs[0] = config.upper;
                active_configs[1] = config.lower;
                clocks[0] = {};
                clocks[1] = {};
                commands[0] = {};
                commands[1] = {};
                acro_commands[0] = {};
                acro_commands[1] = {};
                actuator_commands[0] = {};
                actuator_commands[1] = {};
                measured_altitudes[0] = 0.0;
                measured_altitudes[1] = 0.0;
                command_modes[0] = ReplayCommandMode::Angle;
                command_modes[1] = ReplayCommandMode::Angle;
                vehicle_active[0] = false;
                vehicle_active[1] = false;
                has_pending_collision[0] = false;
                has_pending_collision[1] = false;
                pending_collision_authorities[0] = ReplayControllerAuthority::FlightCore;
                pending_collision_authorities[1] = ReplayControllerAuthority::FlightCore;
                scene_objects.clear();
                environment_json.clear();
                controllers[0].reset_flight(state.upper, clocks[0]);
                controllers[1].reset_flight(state.lower, clocks[1]);
                last_collisions[0] = {};
                last_collisions[1] = {};
                frame_remainder = 0.0;
                break;
            case ReplaySimulationOperation::Respawn:
                state = {config.upper.initial_state, config.lower.initial_state};
                active_configs[0] = config.upper;
                active_configs[1] = config.lower;
                clocks[0] = {};
                clocks[1] = {};
                commands[0] = {};
                commands[1] = {};
                acro_commands[0] = {};
                acro_commands[1] = {};
                actuator_commands[0] = {};
                actuator_commands[1] = {};
                measured_altitudes[0] = 0.0;
                measured_altitudes[1] = 0.0;
                command_modes[0] = ReplayCommandMode::Angle;
                command_modes[1] = ReplayCommandMode::Angle;
                vehicle_active[0] = false;
                vehicle_active[1] = false;
                has_pending_collision[0] = false;
                has_pending_collision[1] = false;
                pending_collision_authorities[0] = ReplayControllerAuthority::FlightCore;
                pending_collision_authorities[1] = ReplayControllerAuthority::FlightCore;
                scene_objects.clear();
                environment_json.clear();
                controllers[0].reset_flight(state.upper, clocks[0]);
                controllers[1].reset_flight(state.lower, clocks[1]);
                last_collisions[0] = {};
                last_collisions[1] = {};
                frame_remainder = 0.0;
                break;
            }
            break;
        }
        if (!has_recorded_checkpoints) {
            checkpoint(event.timestamp_us);
        }
        }
        event_index = group_end;
        if (has_recorded_checkpoints) {
            checkpoint_recorded_at(timestamp_us);
        }
    }
    if (!paused && session.termination_timestamp_us >= previous_timestamp_us &&
            !advance_us(session.termination_timestamp_us - previous_timestamp_us, session.termination_timestamp_us)) {
        if (replay_step_status != StepStatus::Ok) {
            return replay_step_failure();
        }
        return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay termination interval exceeds runtime frame limit"));
    }
    if (!has_recorded_checkpoints) {
        checkpoint(session.termination_timestamp_us);
    } else {
        checkpoint_recorded_at(session.termination_timestamp_us);
    }
    if (has_pending_collision[0] || has_pending_collision[1]) {
        return failed_run(invalid(ReplayDiagnosticCode::InvalidSession, "replay collision was not consumed before termination"));
    }
    return {true, {}, state, clocks[0], session.termination_timestamp_us,
            {session.vehicles[0].name, session.vehicles[1].name}, std::move(scene_objects),
            std::move(environment_json), std::move(checkpoints)};
}

ReplayDivergence compare_replay_runs(
        const ReplayRunResult &expected,
        const ReplayRunResult &actual,
        double numeric_tolerance) {
    const double tolerance = std::max(0.0, numeric_tolerance);
    ReplayDivergence result;
    const auto report_at = [&](std::uint64_t timestamp_us, const std::string &field, double expected_value, double actual_value) {
        result.diverged = true;
        result.timestamp_us = timestamp_us;
        if (field.rfind("upper.", 0) == 0) {
            result.vehicle_name = expected.vehicle_names[0];
        } else if (field.rfind("lower.", 0) == 0) {
            result.vehicle_name = expected.vehicle_names[1];
        }
        result.field = field;
        result.expected = divergence_number(expected_value);
        result.actual = divergence_number(actual_value);
        result.tolerance = tolerance;
    };
    const auto report = [&](const std::string &field, double expected_value, double actual_value) {
        report_at(std::min(expected.final_timestamp_us, actual.final_timestamp_us), field, expected_value, actual_value);
    };
    if (!expected.ok || !actual.ok) {
        result.diverged = true;
        result.field = "run.diagnostic";
        result.expected = expected.diagnostic.message;
        result.actual = actual.diagnostic.message;
        return result;
    }
    if (expected.checkpoints.size() != actual.checkpoints.size()) {
        result.diverged = true;
        result.field = "checkpoints.count";
        result.expected = std::to_string(expected.checkpoints.size());
        result.actual = std::to_string(actual.checkpoints.size());
        return result;
    }
    for (std::size_t checkpoint_index = 0; checkpoint_index < expected.checkpoints.size(); ++checkpoint_index) {
        const ReplayRunCheckpoint &left = expected.checkpoints[checkpoint_index];
        const ReplayRunCheckpoint &right = actual.checkpoints[checkpoint_index];
        if (left.timestamp_us != right.timestamp_us) {
            result.diverged = true;
            result.timestamp_us = std::min(left.timestamp_us, right.timestamp_us);
            result.field = "checkpoint.timestamp_us";
            result.expected = std::to_string(left.timestamp_us);
            result.actual = std::to_string(right.timestamp_us);
            return result;
        }
        const double *left_values[] = {
                &left.state.upper.position.x, &left.state.upper.position.y, &left.state.upper.position.z,
                &left.state.lower.position.x, &left.state.lower.position.y, &left.state.lower.position.z,
                &left.state.upper.velocity.x, &left.state.upper.velocity.y, &left.state.upper.velocity.z,
                &left.state.lower.velocity.x, &left.state.lower.velocity.y, &left.state.lower.velocity.z,
                &left.state.upper.orientation.x, &left.state.upper.orientation.y, &left.state.upper.orientation.z, &left.state.upper.orientation.w,
                &left.state.lower.orientation.x, &left.state.lower.orientation.y, &left.state.lower.orientation.z, &left.state.lower.orientation.w,
                &left.state.upper.angular_velocity.x, &left.state.upper.angular_velocity.y, &left.state.upper.angular_velocity.z,
                &left.state.lower.angular_velocity.x, &left.state.lower.angular_velocity.y, &left.state.lower.angular_velocity.z,
        };
        const double *right_values[] = {
                &right.state.upper.position.x, &right.state.upper.position.y, &right.state.upper.position.z,
                &right.state.lower.position.x, &right.state.lower.position.y, &right.state.lower.position.z,
                &right.state.upper.velocity.x, &right.state.upper.velocity.y, &right.state.upper.velocity.z,
                &right.state.lower.velocity.x, &right.state.lower.velocity.y, &right.state.lower.velocity.z,
                &right.state.upper.orientation.x, &right.state.upper.orientation.y, &right.state.upper.orientation.z, &right.state.upper.orientation.w,
                &right.state.lower.orientation.x, &right.state.lower.orientation.y, &right.state.lower.orientation.z, &right.state.lower.orientation.w,
                &right.state.upper.angular_velocity.x, &right.state.upper.angular_velocity.y, &right.state.upper.angular_velocity.z,
                &right.state.lower.angular_velocity.x, &right.state.lower.angular_velocity.y, &right.state.lower.angular_velocity.z,
        };
        const char *field_names[] = {
                "upper.position.x", "upper.position.y", "upper.position.z", "lower.position.x", "lower.position.y", "lower.position.z",
                "upper.velocity.x", "upper.velocity.y", "upper.velocity.z", "lower.velocity.x", "lower.velocity.y", "lower.velocity.z",
                "upper.orientation.x", "upper.orientation.y", "upper.orientation.z", "upper.orientation.w",
                "lower.orientation.x", "lower.orientation.y", "lower.orientation.z", "lower.orientation.w",
                "upper.angular_velocity.x", "upper.angular_velocity.y", "upper.angular_velocity.z",
                "lower.angular_velocity.x", "lower.angular_velocity.y", "lower.angular_velocity.z",
        };
        for (std::size_t field_index = 0; field_index < sizeof(left_values) / sizeof(left_values[0]); ++field_index) {
            if (!same_or_close(*left_values[field_index], *right_values[field_index], tolerance)) {
                report_at(left.timestamp_us, field_names[field_index], *left_values[field_index], *right_values[field_index]);
                return result;
            }
        }
        if (const char *field = rigid_body_difference(left.state.upper, right.state.upper, tolerance)) {
            report_at(left.timestamp_us, std::string("upper.") + field, 0.0, 0.0);
            return result;
        }
        if (const char *field = rigid_body_difference(left.state.lower, right.state.lower, tolerance)) {
            report_at(left.timestamp_us, std::string("lower.") + field, 0.0, 0.0);
            return result;
        }
        for (std::size_t vehicle = 0; vehicle < 2; ++vehicle) {
            const FlightControlState &left_controller = left.controllers[vehicle];
            const FlightControlState &right_controller = right.controllers[vehicle];
            const double left_controller_values[] = {
                    left_controller.target_angle_frd.x, left_controller.target_angle_frd.y, left_controller.target_angle_frd.z,
                    left_controller.target_rate_frd.x, left_controller.target_rate_frd.y, left_controller.target_rate_frd.z,
                    left_controller.rate_integral[0], left_controller.rate_integral[1], left_controller.rate_integral[2],
                    left_controller.previous_rate_error_frd.x, left_controller.previous_rate_error_frd.y, left_controller.previous_rate_error_frd.z,
                    left_controller.filtered_rate_derivative_frd.x, left_controller.filtered_rate_derivative_frd.y,
                    left_controller.filtered_rate_derivative_frd.z, left_controller.motor_thrust_newtons,
                    left.clocks[vehicle].substep_accumulator, left.first_response_substeps[vehicle].time_seconds,
            };
            const double right_controller_values[] = {
                    right_controller.target_angle_frd.x, right_controller.target_angle_frd.y, right_controller.target_angle_frd.z,
                    right_controller.target_rate_frd.x, right_controller.target_rate_frd.y, right_controller.target_rate_frd.z,
                    right_controller.rate_integral[0], right_controller.rate_integral[1], right_controller.rate_integral[2],
                    right_controller.previous_rate_error_frd.x, right_controller.previous_rate_error_frd.y, right_controller.previous_rate_error_frd.z,
                    right_controller.filtered_rate_derivative_frd.x, right_controller.filtered_rate_derivative_frd.y,
                    right_controller.filtered_rate_derivative_frd.z, right_controller.motor_thrust_newtons,
                    right.clocks[vehicle].substep_accumulator, right.first_response_substeps[vehicle].time_seconds,
            };
            const char *controller_fields[] = {
                    "target_angle_frd.x", "target_angle_frd.y", "target_angle_frd.z",
                    "target_rate_frd.x", "target_rate_frd.y", "target_rate_frd.z",
                    "rate_integral[0]", "rate_integral[1]", "rate_integral[2]",
                    "previous_rate_error_frd.x", "previous_rate_error_frd.y", "previous_rate_error_frd.z",
                    "filtered_rate_derivative_frd.x", "filtered_rate_derivative_frd.y", "filtered_rate_derivative_frd.z",
                    "motor_thrust_newtons", "clock.substep_accumulator", "first_response_substep.time_seconds",
            };
            for (std::size_t field_index = 0; field_index < sizeof(left_controller_values) / sizeof(left_controller_values[0]); ++field_index) {
                if (!same_or_close(left_controller_values[field_index], right_controller_values[field_index], tolerance)) {
                    report_at(left.timestamp_us, "checkpoint.controller[" + std::to_string(vehicle) + "]." + controller_fields[field_index],
                            left_controller_values[field_index], right_controller_values[field_index]);
                    return result;
                }
            }
            if (left_controller.mode_family != right_controller.mode_family ||
                    left_controller.control_initialized != right_controller.control_initialized ||
                    left_controller.altitude_hold_captured != right_controller.altitude_hold_captured ||
                    left_controller.altitude_hold_just_captured != right_controller.altitude_hold_just_captured ||
                    left.clocks[vehicle].total_substeps != right.clocks[vehicle].total_substeps ||
                    left.first_response_substeps[vehicle].substeps != right.first_response_substeps[vehicle].substeps) {
                result.diverged = true;
                result.timestamp_us = left.timestamp_us;
                result.field = "checkpoint.controller[" + std::to_string(vehicle) + "].mode_or_clock";
                result.expected = "different";
                result.actual = "different";
                return result;
            }
            for (std::size_t motor = 0; motor < 4; ++motor) {
                if (left_controller.motor_saturation_latched[motor] != right_controller.motor_saturation_latched[motor] ||
                        !same_or_close(left.first_response_substeps[vehicle].state.motor_thrust_newtons[motor],
                                right.first_response_substeps[vehicle].state.motor_thrust_newtons[motor], tolerance)) {
                    result.diverged = true;
                    result.timestamp_us = left.timestamp_us;
                    result.field = "checkpoint.controller[" + std::to_string(vehicle) + "].motor[" + std::to_string(motor) + "]";
                    result.expected = "different";
                    result.actual = "different";
                    return result;
                }
            }
            if (const char *field = rigid_body_difference(left.first_response_substeps[vehicle].state,
                    right.first_response_substeps[vehicle].state, tolerance)) {
                result.diverged = true;
                result.timestamp_us = left.timestamp_us;
                result.field = "checkpoint.controller[" + std::to_string(vehicle) + "].first_response." + field;
                result.expected = "different";
                result.actual = "different";
                return result;
            }
            if (const char *axis = trajectory_propwash_difference(left.first_response_substeps[vehicle],
                    right.first_response_substeps[vehicle], tolerance)) {
                result.diverged = true;
                result.timestamp_us = left.timestamp_us;
                result.field = "checkpoint.controller[" + std::to_string(vehicle) +
                        "].first_response.propwash_disturbance_rad_s2." + axis;
                result.expected = "different";
                result.actual = "different";
                return result;
            }
            for (std::size_t axis = 0; axis < 3; ++axis) {
                if (left_controller.pid_saturation_latched[axis] != right_controller.pid_saturation_latched[axis]) {
                    result.diverged = true;
                    result.timestamp_us = left.timestamp_us;
                    result.field = "checkpoint.controller[" + std::to_string(vehicle) + "].pid_latch[" + std::to_string(axis) + "]";
                    result.expected = "different";
                    result.actual = "different";
                    return result;
                }
            }
        }
        for (std::size_t vehicle_index = 0; vehicle_index < 2; ++vehicle_index) {
            const ReplayCollision &left_collision = left.collisions[vehicle_index];
            const ReplayCollision &right_collision = right.collisions[vehicle_index];
            const std::string vehicle_name = expected.vehicle_names[vehicle_index];
            const auto report_collision = [&](const std::string &field, const std::string &expected_value,
                                              const std::string &actual_value, double field_tolerance) {
                result.diverged = true;
                result.timestamp_us = left.timestamp_us;
                result.vehicle_name = vehicle_name;
                result.field = field;
                result.expected = expected_value;
                result.actual = actual_value;
                result.tolerance = field_tolerance;
            };
            if (left_collision.authority != right_collision.authority) {
                report_collision("collision.authority", authority_name(left_collision.authority), authority_name(right_collision.authority), 0.0);
                return result;
            }
            if (left_collision.contact.touching != right_collision.contact.touching) {
                report_collision("collision.touching", left_collision.contact.touching ? "true" : "false",
                        right_collision.contact.touching ? "true" : "false", 0.0);
                return result;
            }
            const double *left_collision_values[] = {
                    &left_collision.contact.normal.x, &left_collision.contact.normal.y, &left_collision.contact.normal.z,
                    &left_collision.contact.impulse.x, &left_collision.contact.impulse.y, &left_collision.contact.impulse.z,
                    &left_collision.contact.restitution,
                    &left_collision.contact.resolved_velocity.x, &left_collision.contact.resolved_velocity.y, &left_collision.contact.resolved_velocity.z,
                    &left_collision.contact.resolved_angular_velocity.x, &left_collision.contact.resolved_angular_velocity.y, &left_collision.contact.resolved_angular_velocity.z,
                    &left_collision.contact.max_kinetic_energy_joules,
            };
            const double *right_collision_values[] = {
                    &right_collision.contact.normal.x, &right_collision.contact.normal.y, &right_collision.contact.normal.z,
                    &right_collision.contact.impulse.x, &right_collision.contact.impulse.y, &right_collision.contact.impulse.z,
                    &right_collision.contact.restitution,
                    &right_collision.contact.resolved_velocity.x, &right_collision.contact.resolved_velocity.y, &right_collision.contact.resolved_velocity.z,
                    &right_collision.contact.resolved_angular_velocity.x, &right_collision.contact.resolved_angular_velocity.y, &right_collision.contact.resolved_angular_velocity.z,
                    &right_collision.contact.max_kinetic_energy_joules,
            };
            const char *collision_fields[] = {
                    "collision.normal.x", "collision.normal.y", "collision.normal.z",
                    "collision.impulse.x", "collision.impulse.y", "collision.impulse.z",
                    "collision.restitution",
                    "collision.resolved_velocity.x", "collision.resolved_velocity.y", "collision.resolved_velocity.z",
                    "collision.resolved_angular_velocity.x", "collision.resolved_angular_velocity.y", "collision.resolved_angular_velocity.z",
                    "collision.max_kinetic_energy_joules",
            };
            for (std::size_t collision_field = 0; collision_field < sizeof(left_collision_values) / sizeof(left_collision_values[0]); ++collision_field) {
                if (!same_or_close(*left_collision_values[collision_field], *right_collision_values[collision_field], tolerance)) {
                    report_collision(collision_fields[collision_field], divergence_number(*left_collision_values[collision_field]),
                            divergence_number(*right_collision_values[collision_field]), tolerance);
                    return result;
                }
            }
            if (left_collision.contact.has_resolved_state != right_collision.contact.has_resolved_state) {
                report_collision("collision.has_resolved_state", left_collision.contact.has_resolved_state ? "true" : "false",
                        right_collision.contact.has_resolved_state ? "true" : "false", 0.0);
                return result;
            }
        }
        if (left.scene_objects.size() != right.scene_objects.size()) {
            result.diverged = true;
            result.timestamp_us = left.timestamp_us;
            result.field = "scene_objects.count";
            result.expected = std::to_string(left.scene_objects.size());
            result.actual = std::to_string(right.scene_objects.size());
            return result;
        }
        if (left.environment_json != right.environment_json) {
            result.diverged = true;
            result.timestamp_us = left.timestamp_us;
            result.field = "environment";
            result.expected = left.environment_json;
            result.actual = right.environment_json;
            return result;
        }
        for (std::size_t object_index = 0; object_index < left.scene_objects.size(); ++object_index) {
            const ReplaySceneObjectState &left_object = left.scene_objects[object_index];
            const ReplaySceneObjectState &right_object = right.scene_objects[object_index];
            if (left_object.name != right_object.name || left_object.asset_id != right_object.asset_id) {
                result.diverged = true;
                result.timestamp_us = left.timestamp_us;
                result.field = "scene_object.identity";
                result.expected = left_object.name + ":" + left_object.asset_id;
                result.actual = right_object.name + ":" + right_object.asset_id;
                return result;
            }
            const double *left_transform[] = {
                    &left_object.position.x, &left_object.position.y, &left_object.position.z,
                    &left_object.orientation.x, &left_object.orientation.y, &left_object.orientation.z, &left_object.orientation.w,
            };
            const double *right_transform[] = {
                    &right_object.position.x, &right_object.position.y, &right_object.position.z,
                    &right_object.orientation.x, &right_object.orientation.y, &right_object.orientation.z, &right_object.orientation.w,
            };
            const char *transform_fields[] = {"position.x", "position.y", "position.z", "orientation.x", "orientation.y", "orientation.z", "orientation.w"};
            for (std::size_t transform_index = 0; transform_index < sizeof(left_transform) / sizeof(left_transform[0]); ++transform_index) {
                if (!same_or_close(*left_transform[transform_index], *right_transform[transform_index], tolerance)) {
                    report_at(left.timestamp_us, "scene_object." + std::string(transform_fields[transform_index]),
                            *left_transform[transform_index], *right_transform[transform_index]);
                    return result;
                }
            }
        }
    }
    const double *expected_values[] = {
            &expected.final_state.upper.position.x, &expected.final_state.upper.position.y, &expected.final_state.upper.position.z,
            &expected.final_state.lower.position.x, &expected.final_state.lower.position.y, &expected.final_state.lower.position.z,
            &expected.final_state.upper.velocity.x, &expected.final_state.upper.velocity.y, &expected.final_state.upper.velocity.z,
            &expected.final_state.lower.velocity.x, &expected.final_state.lower.velocity.y, &expected.final_state.lower.velocity.z,
    };
    const double *actual_values[] = {
            &actual.final_state.upper.position.x, &actual.final_state.upper.position.y, &actual.final_state.upper.position.z,
            &actual.final_state.lower.position.x, &actual.final_state.lower.position.y, &actual.final_state.lower.position.z,
            &actual.final_state.upper.velocity.x, &actual.final_state.upper.velocity.y, &actual.final_state.upper.velocity.z,
            &actual.final_state.lower.velocity.x, &actual.final_state.lower.velocity.y, &actual.final_state.lower.velocity.z,
    };
    const char *fields[] = {
            "upper.position.x", "upper.position.y", "upper.position.z",
            "lower.position.x", "lower.position.y", "lower.position.z",
            "upper.velocity.x", "upper.velocity.y", "upper.velocity.z",
            "lower.velocity.x", "lower.velocity.y", "lower.velocity.z",
    };
    for (std::size_t index = 0; index < sizeof(expected_values) / sizeof(expected_values[0]); ++index) {
        if (!same_or_close(*expected_values[index], *actual_values[index], tolerance)) {
            report(fields[index], *expected_values[index], *actual_values[index]);
            return result;
        }
    }
    const double *expected_attitude[] = {
            &expected.final_state.upper.orientation.x, &expected.final_state.upper.orientation.y,
            &expected.final_state.upper.orientation.z, &expected.final_state.upper.orientation.w,
            &expected.final_state.lower.orientation.x, &expected.final_state.lower.orientation.y,
            &expected.final_state.lower.orientation.z, &expected.final_state.lower.orientation.w,
            &expected.final_state.upper.angular_velocity.x, &expected.final_state.upper.angular_velocity.y,
            &expected.final_state.upper.angular_velocity.z, &expected.final_state.lower.angular_velocity.x,
            &expected.final_state.lower.angular_velocity.y, &expected.final_state.lower.angular_velocity.z,
    };
    const double *actual_attitude[] = {
            &actual.final_state.upper.orientation.x, &actual.final_state.upper.orientation.y,
            &actual.final_state.upper.orientation.z, &actual.final_state.upper.orientation.w,
            &actual.final_state.lower.orientation.x, &actual.final_state.lower.orientation.y,
            &actual.final_state.lower.orientation.z, &actual.final_state.lower.orientation.w,
            &actual.final_state.upper.angular_velocity.x, &actual.final_state.upper.angular_velocity.y,
            &actual.final_state.upper.angular_velocity.z, &actual.final_state.lower.angular_velocity.x,
            &actual.final_state.lower.angular_velocity.y, &actual.final_state.lower.angular_velocity.z,
    };
    const char *attitude_fields[] = {
            "upper.orientation.x", "upper.orientation.y", "upper.orientation.z", "upper.orientation.w",
            "lower.orientation.x", "lower.orientation.y", "lower.orientation.z", "lower.orientation.w",
            "upper.angular_velocity.x", "upper.angular_velocity.y", "upper.angular_velocity.z",
            "lower.angular_velocity.x", "lower.angular_velocity.y", "lower.angular_velocity.z",
    };
    for (std::size_t index = 0; index < sizeof(expected_attitude) / sizeof(expected_attitude[0]); ++index) {
        if (!same_or_close(*expected_attitude[index], *actual_attitude[index], tolerance)) {
            report(attitude_fields[index], *expected_attitude[index], *actual_attitude[index]);
            return result;
        }
    }
    if (expected.final_clock.total_substeps != actual.final_clock.total_substeps) {
        result.diverged = true;
        result.field = "final_clock.total_substeps";
        result.expected = std::to_string(expected.final_clock.total_substeps);
        result.actual = std::to_string(actual.final_clock.total_substeps);
        return result;
    }
    if (expected.final_timestamp_us != actual.final_timestamp_us) {
        result.diverged = true;
        result.timestamp_us = std::min(expected.final_timestamp_us, actual.final_timestamp_us);
        result.field = "final_timestamp_us";
        result.expected = std::to_string(expected.final_timestamp_us);
        result.actual = std::to_string(actual.final_timestamp_us);
        return result;
    }
    if (expected.scene_objects.size() != actual.scene_objects.size()) {
        result.diverged = true;
        result.field = "scene_objects.count";
        result.expected = std::to_string(expected.scene_objects.size());
        result.actual = std::to_string(actual.scene_objects.size());
        return result;
    }
    for (std::size_t object_index = 0; object_index < expected.scene_objects.size(); ++object_index) {
        const ReplaySceneObjectState &left_object = expected.scene_objects[object_index];
        const ReplaySceneObjectState &right_object = actual.scene_objects[object_index];
        if (left_object.name != right_object.name || left_object.asset_id != right_object.asset_id) {
            result.diverged = true;
            result.timestamp_us = std::min(expected.final_timestamp_us, actual.final_timestamp_us);
            result.field = "scene_object.identity";
            result.expected = left_object.name + ":" + left_object.asset_id;
            result.actual = right_object.name + ":" + right_object.asset_id;
            return result;
        }
        const double *left_transform[] = {
                &left_object.position.x, &left_object.position.y, &left_object.position.z,
                &left_object.orientation.x, &left_object.orientation.y, &left_object.orientation.z, &left_object.orientation.w,
        };
        const double *right_transform[] = {
                &right_object.position.x, &right_object.position.y, &right_object.position.z,
                &right_object.orientation.x, &right_object.orientation.y, &right_object.orientation.z, &right_object.orientation.w,
        };
        const char *transform_fields[] = {
                "scene_object.position.x", "scene_object.position.y", "scene_object.position.z",
                "scene_object.orientation.x", "scene_object.orientation.y", "scene_object.orientation.z", "scene_object.orientation.w",
        };
        for (std::size_t transform_index = 0; transform_index < sizeof(left_transform) / sizeof(left_transform[0]); ++transform_index) {
            if (!same_or_close(*left_transform[transform_index], *right_transform[transform_index], tolerance)) {
                report_at(std::min(expected.final_timestamp_us, actual.final_timestamp_us), transform_fields[transform_index],
                        *left_transform[transform_index], *right_transform[transform_index]);
                return result;
            }
        }
    }
    if (expected.environment_json != actual.environment_json) {
        result.diverged = true;
        result.field = "environment";
        result.expected = expected.environment_json;
        result.actual = actual.environment_json;
    }
    return result;
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
            if (left.command_mode != right.command_mode) {
                report(left.timestamp_us, left.vehicle_name, "command.mode", command_mode_name(left.command_mode), command_mode_name(right.command_mode), 0.0);
                return result;
            }
            if (!same_or_close(left.measured_altitude_m, right.measured_altitude_m, tolerance)) {
                report(left.timestamp_us, left.vehicle_name, "command.measured_altitude_m",
                        divergence_number(left.measured_altitude_m), divergence_number(right.measured_altitude_m), tolerance);
                return result;
            }
            const double left_values[] = {left.command.throttle, left.command.roll_degrees, left.command.pitch_degrees, left.command.yaw_rate_degrees_per_second, left.command.vertical_velocity_mps};
            const double right_values[] = {right.command.throttle, right.command.roll_degrees, right.command.pitch_degrees, right.command.yaw_rate_degrees_per_second, right.command.vertical_velocity_mps};
            const char *fields[] = {"command.throttle", "command.roll_degrees", "command.pitch_degrees", "command.yaw_rate_degrees_per_second", "command.vertical_velocity_mps"};
            for (int value_index = 0; value_index < 5; ++value_index) {
                if (!same_or_close(left_values[value_index], right_values[value_index], tolerance)) {
                    report(left.timestamp_us, left.vehicle_name, fields[value_index], divergence_number(left_values[value_index]), divergence_number(right_values[value_index]), tolerance);
                    return result;
                }
            }
            if (left.command.heading_hold_enabled != right.command.heading_hold_enabled ||
                    left.command.position_hold_enabled != right.command.position_hold_enabled) {
                report(left.timestamp_us, left.vehicle_name, "command.assisted_hold", "different", "different", tolerance);
                return result;
            }
            if (left.command_mode == ReplayCommandMode::Acro) {
                const double left_acro_values[] = {left.acro_command.throttle, left.acro_command.roll_stick,
                        left.acro_command.pitch_stick, left.acro_command.yaw_stick, left.acro_command.rates.rc_rate,
                        left.acro_command.rates.super_rate, left.acro_command.rates.expo};
                const double right_acro_values[] = {right.acro_command.throttle, right.acro_command.roll_stick,
                        right.acro_command.pitch_stick, right.acro_command.yaw_stick, right.acro_command.rates.rc_rate,
                        right.acro_command.rates.super_rate, right.acro_command.rates.expo};
                const char *acro_fields[] = {"command.acro.throttle", "command.acro.roll_stick", "command.acro.pitch_stick",
                        "command.acro.yaw_stick", "command.acro.rc_rate", "command.acro.super_rate", "command.acro.expo"};
                for (int value_index = 0; value_index < 7; ++value_index) {
                    if (!same_or_close(left_acro_values[value_index], right_acro_values[value_index], tolerance)) {
                        report(left.timestamp_us, left.vehicle_name, acro_fields[value_index],
                                divergence_number(left_acro_values[value_index]), divergence_number(right_acro_values[value_index]), tolerance);
                        return result;
                    }
                }
            } else if (left.command_mode == ReplayCommandMode::Actuator) {
                for (std::size_t value_index = 0; value_index < left.actuator_commands.size(); ++value_index) {
                    if (!same_or_close(left.actuator_commands[value_index], right.actuator_commands[value_index], tolerance)) {
                        report(left.timestamp_us, left.vehicle_name, "command.actuator_" + std::to_string(value_index),
                                divergence_number(left.actuator_commands[value_index]),
                                divergence_number(right.actuator_commands[value_index]), tolerance);
                        return result;
                    }
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
        } else if (left.type == ReplayEventType::QuickAdjustBinding &&
                left.quick_adjust_profile_json != right.quick_adjust_profile_json) {
            report(left.timestamp_us, {}, "quick_adjust_binding", left.quick_adjust_profile_json,
                    right.quick_adjust_profile_json, 0.0);
            return result;
        } else if (left.type == ReplayEventType::SimulationTime) {
            if (left.simulation_operation != right.simulation_operation) {
                report(left.timestamp_us, {}, "simulation.operation", simulation_operation_name(left.simulation_operation), simulation_operation_name(right.simulation_operation), 0.0);
                return result;
            }
            if (!same_or_close(left.simulation_value, right.simulation_value, tolerance)) {
                report(left.timestamp_us, {}, "simulation.value", divergence_number(left.simulation_value), divergence_number(right.simulation_value), 0.0);
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
            } else if (!same_or_close(left.collision.contact.normal.x, right.collision.contact.normal.x, tolerance) ||
                    !same_or_close(left.collision.contact.normal.y, right.collision.contact.normal.y, tolerance) ||
                    !same_or_close(left.collision.contact.normal.z, right.collision.contact.normal.z, tolerance)) {
                report(left.timestamp_us, left.vehicle_name, "collision.normal", vec_json(left.collision.contact.normal), vec_json(right.collision.contact.normal), tolerance);
            } else if (!same_or_close(left.collision.contact.impulse.x, right.collision.contact.impulse.x, tolerance) ||
                    !same_or_close(left.collision.contact.impulse.y, right.collision.contact.impulse.y, tolerance) ||
                    !same_or_close(left.collision.contact.impulse.z, right.collision.contact.impulse.z, tolerance)) {
                report(left.timestamp_us, left.vehicle_name, "collision.impulse", vec_json(left.collision.contact.impulse), vec_json(right.collision.contact.impulse), tolerance);
            } else if (!same_or_close(left.collision.contact.restitution, right.collision.contact.restitution, tolerance)) {
                report(left.timestamp_us, left.vehicle_name, "collision.restitution",
                        divergence_number(left.collision.contact.restitution), divergence_number(right.collision.contact.restitution), tolerance);
            } else if (left.collision.contact.has_resolved_state != right.collision.contact.has_resolved_state) {
                report(left.timestamp_us, left.vehicle_name, "collision.has_resolved_state",
                        left.collision.contact.has_resolved_state ? "true" : "false",
                        right.collision.contact.has_resolved_state ? "true" : "false", 0.0);
            } else {
                const double left_values[] = {
                        left.collision.contact.resolved_velocity.x, left.collision.contact.resolved_velocity.y,
                        left.collision.contact.resolved_velocity.z, left.collision.contact.resolved_angular_velocity.x,
                        left.collision.contact.resolved_angular_velocity.y, left.collision.contact.resolved_angular_velocity.z,
                        left.collision.contact.max_kinetic_energy_joules,
                };
                const double right_values[] = {
                        right.collision.contact.resolved_velocity.x, right.collision.contact.resolved_velocity.y,
                        right.collision.contact.resolved_velocity.z, right.collision.contact.resolved_angular_velocity.x,
                        right.collision.contact.resolved_angular_velocity.y, right.collision.contact.resolved_angular_velocity.z,
                        right.collision.contact.max_kinetic_energy_joules,
                };
                const char *fields[] = {
                        "collision.resolved_velocity.x", "collision.resolved_velocity.y", "collision.resolved_velocity.z",
                        "collision.resolved_angular_velocity.x", "collision.resolved_angular_velocity.y",
                        "collision.resolved_angular_velocity.z", "collision.max_kinetic_energy_joules",
                };
                for (std::size_t index = 0; index < sizeof(left_values) / sizeof(left_values[0]); ++index) {
                    if (!same_or_close(left_values[index], right_values[index], tolerance)) {
                        report(left.timestamp_us, left.vehicle_name, fields[index],
                                divergence_number(left_values[index]), divergence_number(right_values[index]), tolerance);
                        break;
                    }
                }
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
                const double left_values[] = {
                        left.object_position.x, left.object_position.y, left.object_position.z,
                        left.object_orientation.x, left.object_orientation.y,
                        left.object_orientation.z, left.object_orientation.w,
                };
                const double right_values[] = {
                        right.object_position.x, right.object_position.y, right.object_position.z,
                        right.object_orientation.x, right.object_orientation.y,
                        right.object_orientation.z, right.object_orientation.w,
                };
                const char *fields[] = {
                        "scene_object.position.x", "scene_object.position.y", "scene_object.position.z",
                        "scene_object.orientation.x", "scene_object.orientation.y",
                        "scene_object.orientation.z", "scene_object.orientation.w",
                };
                for (std::size_t index = 0; index < sizeof(left_values) / sizeof(left_values[0]); ++index) {
                    if (!same_or_close(left_values[index], right_values[index], tolerance)) {
                        report(left.timestamp_us, {}, fields[index],
                                divergence_number(left_values[index]), divergence_number(right_values[index]), tolerance);
                        break;
                    }
                }
            }
            return result;
        } else if (left.type == ReplayEventType::Environment && left.environment_json != right.environment_json) {
            report(left.timestamp_us, {}, "environment", left.environment_json, right.environment_json, 0.0);
            return result;
        } else if (left.type == ReplayEventType::Tuning &&
                (left.tuning_request_seq != right.tuning_request_seq || left.tuning_commit_id != right.tuning_commit_id ||
                 left.tuning_parameter != right.tuning_parameter || left.tuning_clamped != right.tuning_clamped ||
                 left.tuning_source != right.tuning_source || left.tuning_quick_adjust_slot != right.tuning_quick_adjust_slot ||
                 !same_or_close(left.tuning_requested_value, right.tuning_requested_value, tolerance) ||
                 !same_or_close(left.tuning_committed_value, right.tuning_committed_value, tolerance))) {
            report(left.timestamp_us, left.vehicle_name, "tuning", event_json(left), event_json(right), tolerance);
            return result;
        }
    }
    if (expected.checkpoints.size() != actual.checkpoints.size()) {
        report(0, {}, "checkpoints.count", std::to_string(expected.checkpoints.size()),
                std::to_string(actual.checkpoints.size()), 0.0);
        return result;
    }
    for (std::size_t index = 0; index < expected.checkpoints.size(); ++index) {
        const ReplayRunCheckpoint &left = expected.checkpoints[index];
        const ReplayRunCheckpoint &right = actual.checkpoints[index];
        if (left.timestamp_us != right.timestamp_us) {
            report(std::min(left.timestamp_us, right.timestamp_us), {}, "checkpoint.timestamp_us",
                    std::to_string(left.timestamp_us), std::to_string(right.timestamp_us), 0.0);
            return result;
        }
        const double left_values[] = {
                left.state.upper.position.x, left.state.upper.position.y, left.state.upper.position.z,
                left.state.lower.position.x, left.state.lower.position.y, left.state.lower.position.z,
                left.state.upper.velocity.x, left.state.upper.velocity.y, left.state.upper.velocity.z,
                left.state.lower.velocity.x, left.state.lower.velocity.y, left.state.lower.velocity.z,
                left.state.upper.orientation.x, left.state.upper.orientation.y, left.state.upper.orientation.z, left.state.upper.orientation.w,
                left.state.lower.orientation.x, left.state.lower.orientation.y, left.state.lower.orientation.z, left.state.lower.orientation.w,
                left.state.upper.angular_velocity.x, left.state.upper.angular_velocity.y, left.state.upper.angular_velocity.z,
                left.state.lower.angular_velocity.x, left.state.lower.angular_velocity.y, left.state.lower.angular_velocity.z,
        };
        const double right_values[] = {
                right.state.upper.position.x, right.state.upper.position.y, right.state.upper.position.z,
                right.state.lower.position.x, right.state.lower.position.y, right.state.lower.position.z,
                right.state.upper.velocity.x, right.state.upper.velocity.y, right.state.upper.velocity.z,
                right.state.lower.velocity.x, right.state.lower.velocity.y, right.state.lower.velocity.z,
                right.state.upper.orientation.x, right.state.upper.orientation.y, right.state.upper.orientation.z, right.state.upper.orientation.w,
                right.state.lower.orientation.x, right.state.lower.orientation.y, right.state.lower.orientation.z, right.state.lower.orientation.w,
                right.state.upper.angular_velocity.x, right.state.upper.angular_velocity.y, right.state.upper.angular_velocity.z,
                right.state.lower.angular_velocity.x, right.state.lower.angular_velocity.y, right.state.lower.angular_velocity.z,
        };
        const char *fields[] = {
                "checkpoint.upper.position.x", "checkpoint.upper.position.y", "checkpoint.upper.position.z",
                "checkpoint.lower.position.x", "checkpoint.lower.position.y", "checkpoint.lower.position.z",
                "checkpoint.upper.velocity.x", "checkpoint.upper.velocity.y", "checkpoint.upper.velocity.z",
                "checkpoint.lower.velocity.x", "checkpoint.lower.velocity.y", "checkpoint.lower.velocity.z",
                "checkpoint.upper.orientation.x", "checkpoint.upper.orientation.y", "checkpoint.upper.orientation.z", "checkpoint.upper.orientation.w",
                "checkpoint.lower.orientation.x", "checkpoint.lower.orientation.y", "checkpoint.lower.orientation.z", "checkpoint.lower.orientation.w",
                "checkpoint.upper.angular_velocity.x", "checkpoint.upper.angular_velocity.y", "checkpoint.upper.angular_velocity.z",
                "checkpoint.lower.angular_velocity.x", "checkpoint.lower.angular_velocity.y", "checkpoint.lower.angular_velocity.z",
        };
        for (std::size_t field_index = 0; field_index < sizeof(left_values) / sizeof(left_values[0]); ++field_index) {
            if (!same_or_close(left_values[field_index], right_values[field_index], tolerance)) {
                report(left.timestamp_us, {}, fields[field_index], divergence_number(left_values[field_index]),
                        divergence_number(right_values[field_index]), tolerance);
                return result;
            }
        }
        if (const char *field = rigid_body_difference(left.state.upper, right.state.upper, tolerance)) {
            report(left.timestamp_us, {}, std::string("checkpoint.upper.") + field, "different", "different", 0.0);
            return result;
        }
        if (const char *field = rigid_body_difference(left.state.lower, right.state.lower, tolerance)) {
            report(left.timestamp_us, {}, std::string("checkpoint.lower.") + field, "different", "different", 0.0);
            return result;
        }
        for (std::size_t vehicle = 0; vehicle < 2; ++vehicle) {
            const FlightControlState &left_controller = left.controllers[vehicle];
            const FlightControlState &right_controller = right.controllers[vehicle];
            const double left_controller_values[] = {
                    left_controller.target_angle_frd.x, left_controller.target_angle_frd.y, left_controller.target_angle_frd.z,
                    left_controller.target_rate_frd.x, left_controller.target_rate_frd.y, left_controller.target_rate_frd.z,
                    left_controller.rate_integral[0], left_controller.rate_integral[1], left_controller.rate_integral[2],
                    left_controller.previous_rate_error_frd.x, left_controller.previous_rate_error_frd.y, left_controller.previous_rate_error_frd.z,
                    left_controller.filtered_rate_derivative_frd.x, left_controller.filtered_rate_derivative_frd.y,
                    left_controller.filtered_rate_derivative_frd.z, left_controller.motor_thrust_newtons,
                    left.clocks[vehicle].substep_accumulator, left.first_response_substeps[vehicle].time_seconds,
            };
            const double right_controller_values[] = {
                    right_controller.target_angle_frd.x, right_controller.target_angle_frd.y, right_controller.target_angle_frd.z,
                    right_controller.target_rate_frd.x, right_controller.target_rate_frd.y, right_controller.target_rate_frd.z,
                    right_controller.rate_integral[0], right_controller.rate_integral[1], right_controller.rate_integral[2],
                    right_controller.previous_rate_error_frd.x, right_controller.previous_rate_error_frd.y, right_controller.previous_rate_error_frd.z,
                    right_controller.filtered_rate_derivative_frd.x, right_controller.filtered_rate_derivative_frd.y,
                    right_controller.filtered_rate_derivative_frd.z, right_controller.motor_thrust_newtons,
                    right.clocks[vehicle].substep_accumulator, right.first_response_substeps[vehicle].time_seconds,
            };
            const char *controller_fields[] = {
                    "target_angle_frd.x", "target_angle_frd.y", "target_angle_frd.z",
                    "target_rate_frd.x", "target_rate_frd.y", "target_rate_frd.z",
                    "rate_integral[0]", "rate_integral[1]", "rate_integral[2]",
                    "previous_rate_error_frd.x", "previous_rate_error_frd.y", "previous_rate_error_frd.z",
                    "filtered_rate_derivative_frd.x", "filtered_rate_derivative_frd.y", "filtered_rate_derivative_frd.z",
                    "motor_thrust_newtons", "clock.substep_accumulator", "first_response_substep.time_seconds",
            };
            for (std::size_t field_index = 0; field_index < sizeof(left_controller_values) / sizeof(left_controller_values[0]); ++field_index) {
                if (!same_or_close(left_controller_values[field_index], right_controller_values[field_index], tolerance)) {
                    report(left.timestamp_us, {}, "checkpoint.controller[" + std::to_string(vehicle) + "]." + controller_fields[field_index],
                            divergence_number(left_controller_values[field_index]), divergence_number(right_controller_values[field_index]), tolerance);
                    return result;
                }
            }
            if (left_controller.mode_family != right_controller.mode_family ||
                    left_controller.control_initialized != right_controller.control_initialized ||
                    left_controller.altitude_hold_captured != right_controller.altitude_hold_captured ||
                    left_controller.altitude_hold_just_captured != right_controller.altitude_hold_just_captured ||
                    left.clocks[vehicle].total_substeps != right.clocks[vehicle].total_substeps ||
                    left.first_response_substeps[vehicle].substeps != right.first_response_substeps[vehicle].substeps) {
                report(left.timestamp_us, {}, "checkpoint.controller[" + std::to_string(vehicle) + "].mode_or_clock",
                        "different", "different", 0.0);
                return result;
            }
            for (std::size_t motor = 0; motor < 4; ++motor) {
                if (left_controller.motor_saturation_latched[motor] != right_controller.motor_saturation_latched[motor] ||
                        !same_or_close(left.first_response_substeps[vehicle].state.motor_thrust_newtons[motor],
                                right.first_response_substeps[vehicle].state.motor_thrust_newtons[motor], tolerance)) {
                    report(left.timestamp_us, {}, "checkpoint.controller[" + std::to_string(vehicle) + "].motor[" +
                                    std::to_string(motor) + "]", "different", "different", 0.0);
                    return result;
                }
            }
            if (const char *field = rigid_body_difference(left.first_response_substeps[vehicle].state,
                    right.first_response_substeps[vehicle].state, tolerance)) {
                report(left.timestamp_us, {}, "checkpoint.controller[" + std::to_string(vehicle) + "].first_response." + field,
                        "different", "different", 0.0);
                return result;
            }
            if (const char *axis = trajectory_propwash_difference(left.first_response_substeps[vehicle],
                    right.first_response_substeps[vehicle], tolerance)) {
                report(left.timestamp_us, {}, "checkpoint.controller[" + std::to_string(vehicle) +
                                "].first_response.propwash_disturbance_rad_s2." + axis,
                        "different", "different", 0.0);
                return result;
            }
            for (std::size_t axis = 0; axis < 3; ++axis) {
                if (left_controller.pid_saturation_latched[axis] != right_controller.pid_saturation_latched[axis]) {
                    report(left.timestamp_us, {}, "checkpoint.controller[" + std::to_string(vehicle) + "].pid_latch[" +
                                    std::to_string(axis) + "]", "different", "different", 0.0);
                    return result;
                }
            }
        }
        for (std::size_t vehicle_index = 0; vehicle_index < left.collisions.size(); ++vehicle_index) {
            const ReplayCollision &left_collision = left.collisions[vehicle_index];
            const ReplayCollision &right_collision = right.collisions[vehicle_index];
            const std::string &vehicle_name = expected.vehicles[vehicle_index].name;
            if (left_collision.authority != right_collision.authority) {
                report(left.timestamp_us, vehicle_name, "checkpoint.collision.authority",
                        authority_name(left_collision.authority), authority_name(right_collision.authority), 0.0);
                return result;
            }
            if (left_collision.contact.touching != right_collision.contact.touching) {
                report(left.timestamp_us, vehicle_name, "checkpoint.collision.touching",
                        left_collision.contact.touching ? "true" : "false",
                        right_collision.contact.touching ? "true" : "false", 0.0);
                return result;
            }
            const double left_collision_values[] = {
                    left_collision.contact.normal.x, left_collision.contact.normal.y, left_collision.contact.normal.z,
                    left_collision.contact.impulse.x, left_collision.contact.impulse.y, left_collision.contact.impulse.z,
                    left_collision.contact.restitution,
                    left_collision.contact.resolved_velocity.x, left_collision.contact.resolved_velocity.y, left_collision.contact.resolved_velocity.z,
                    left_collision.contact.resolved_angular_velocity.x, left_collision.contact.resolved_angular_velocity.y,
                    left_collision.contact.resolved_angular_velocity.z, left_collision.contact.max_kinetic_energy_joules,
            };
            const double right_collision_values[] = {
                    right_collision.contact.normal.x, right_collision.contact.normal.y, right_collision.contact.normal.z,
                    right_collision.contact.impulse.x, right_collision.contact.impulse.y, right_collision.contact.impulse.z,
                    right_collision.contact.restitution,
                    right_collision.contact.resolved_velocity.x, right_collision.contact.resolved_velocity.y, right_collision.contact.resolved_velocity.z,
                    right_collision.contact.resolved_angular_velocity.x, right_collision.contact.resolved_angular_velocity.y,
                    right_collision.contact.resolved_angular_velocity.z, right_collision.contact.max_kinetic_energy_joules,
            };
            const char *collision_fields[] = {
                    "checkpoint.collision.normal.x", "checkpoint.collision.normal.y", "checkpoint.collision.normal.z",
                    "checkpoint.collision.impulse.x", "checkpoint.collision.impulse.y", "checkpoint.collision.impulse.z",
                    "checkpoint.collision.restitution",
                    "checkpoint.collision.resolved_velocity.x", "checkpoint.collision.resolved_velocity.y", "checkpoint.collision.resolved_velocity.z",
                    "checkpoint.collision.resolved_angular_velocity.x", "checkpoint.collision.resolved_angular_velocity.y",
                    "checkpoint.collision.resolved_angular_velocity.z", "checkpoint.collision.max_kinetic_energy_joules",
            };
            for (std::size_t collision_index = 0; collision_index < sizeof(left_collision_values) / sizeof(left_collision_values[0]); ++collision_index) {
                if (!same_or_close(left_collision_values[collision_index], right_collision_values[collision_index], tolerance)) {
                    report(left.timestamp_us, vehicle_name, collision_fields[collision_index],
                            divergence_number(left_collision_values[collision_index]),
                            divergence_number(right_collision_values[collision_index]), tolerance);
                    return result;
                }
            }
            if (left_collision.contact.has_resolved_state != right_collision.contact.has_resolved_state) {
                report(left.timestamp_us, vehicle_name, "checkpoint.collision.has_resolved_state",
                        left_collision.contact.has_resolved_state ? "true" : "false",
                        right_collision.contact.has_resolved_state ? "true" : "false", 0.0);
                return result;
            }
        }
        if (left.scene_objects.size() != right.scene_objects.size()) {
            report(left.timestamp_us, {}, "checkpoint.scene_objects.count", std::to_string(left.scene_objects.size()),
                    std::to_string(right.scene_objects.size()), 0.0);
            return result;
        }
        for (std::size_t object_index = 0; object_index < left.scene_objects.size(); ++object_index) {
            const ReplaySceneObjectState &left_object = left.scene_objects[object_index];
            const ReplaySceneObjectState &right_object = right.scene_objects[object_index];
            if (left_object.name != right_object.name || left_object.asset_id != right_object.asset_id) {
                report(left.timestamp_us, {}, "checkpoint.scene_object.identity", left_object.name + ":" + left_object.asset_id,
                        right_object.name + ":" + right_object.asset_id, 0.0);
                return result;
            }
            const double left_transform[] = {
                    left_object.position.x, left_object.position.y, left_object.position.z,
                    left_object.orientation.x, left_object.orientation.y, left_object.orientation.z, left_object.orientation.w,
            };
            const double right_transform[] = {
                    right_object.position.x, right_object.position.y, right_object.position.z,
                    right_object.orientation.x, right_object.orientation.y, right_object.orientation.z, right_object.orientation.w,
            };
            const char *transform_fields[] = {
                    "checkpoint.scene_object.position.x", "checkpoint.scene_object.position.y", "checkpoint.scene_object.position.z",
                    "checkpoint.scene_object.orientation.x", "checkpoint.scene_object.orientation.y",
                    "checkpoint.scene_object.orientation.z", "checkpoint.scene_object.orientation.w",
            };
            for (std::size_t transform_index = 0; transform_index < sizeof(left_transform) / sizeof(left_transform[0]); ++transform_index) {
                if (!same_or_close(left_transform[transform_index], right_transform[transform_index], tolerance)) {
                    report(left.timestamp_us, {}, transform_fields[transform_index], divergence_number(left_transform[transform_index]),
                            divergence_number(right_transform[transform_index]), tolerance);
                    return result;
                }
            }
        }
        if (left.environment_json != right.environment_json) {
            report(left.timestamp_us, {}, "checkpoint.environment", left.environment_json, right.environment_json, 0.0);
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
