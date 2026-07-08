#include "aerosim_imu.hpp"

#include <algorithm>
#include <cmath>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

double sample_dt(const ImuConfig &config) {
    return config.sample_hz > 0.0 ? 1.0 / config.sample_hz : 1.0 / 240.0;
}

Vec3 operator+(const Vec3 &a, const Vec3 &b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Quat normalized(const Quat &q) {
    const double norm = quat_norm(q);
    if (!std::isfinite(norm) || norm == 0.0) {
        return {};
    }
    return {q.x / norm, q.y / norm, q.z / norm, q.w / norm};
}

Quat multiply(const Quat &a, const Quat &b) {
    return {
            a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

Vec3 rotate(const Quat &q, const Vec3 &v) {
    const Quat unit = normalized(q);
    const Quat vector{v.x, v.y, v.z, 0.0};
    const Quat inverse{-unit.x, -unit.y, -unit.z, unit.w};
    const Quat rotated = multiply(multiply(unit, vector), inverse);
    return {rotated.x, rotated.y, rotated.z};
}

Quat from_axis_angle(Vec3 axis, double radians) {
    const double half = radians * 0.5;
    const double s = std::sin(half);
    return {axis.x * s, axis.y * s, axis.z * s, std::cos(half)};
}

Quat from_angles(double x, double y, double z) {
    return normalized(multiply(multiply(
            from_axis_angle({0.0, 1.0, 0.0}, y),
            from_axis_angle({1.0, 0.0, 0.0}, x)),
            from_axis_angle({0.0, 0.0, 1.0}, z)));
}

double angle_x(const Quat &q) {
    return 2.0 * std::atan2(q.x, q.w);
}

double angle_y(const Quat &q) {
    return 2.0 * std::atan2(q.y, q.w);
}

double angle_z(const Quat &q) {
    return 2.0 * std::atan2(q.z, q.w);
}

Quat integrate_gyro(const Quat &attitude, const Vec3 &gyro, double dt) {
    const Quat omega{gyro.x, gyro.y, gyro.z, 0.0};
    const Quat q_dot = multiply(attitude, omega);
    return normalized({
            attitude.x + 0.5 * q_dot.x * dt,
            attitude.y + 0.5 * q_dot.y * dt,
            attitude.z + 0.5 * q_dot.z * dt,
            attitude.w + 0.5 * q_dot.w * dt,
    });
}

double clamp_gain(double gain) {
    if (!std::isfinite(gain)) {
        return 0.0;
    }
    return std::clamp(gain, 0.0, 1.0);
}

bool zero_vec(const Vec3 &v) {
    return v.x == 0.0 && v.y == 0.0 && v.z == 0.0;
}

bool ideal_attitude_source(const ImuConfig &config) {
    return zero_vec(config.gyro_bias) &&
            zero_vec(config.accel_bias) &&
            config.gyro_noise_density == 0.0 &&
            config.accel_noise_density == 0.0 &&
            config.gyro_bias_drift_stddev == 0.0 &&
            config.accel_bias_drift_stddev == 0.0 &&
            config.gyro_random_walk_stddev == 0.0 &&
            config.accel_random_walk_stddev == 0.0;
}

} // namespace

ImuSimulator::ImuSimulator(const ImuConfig &config) :
        config_(config),
        rng_(config.seed),
        normal_(0.0, 1.0) {}

void ImuSimulator::reset(std::uint32_t seed) {
    config_.seed = seed;
    rng_.seed(seed);
    normal_.reset();
    history_.clear();
    gyro_bias_ = {};
    accel_bias_ = {};
    gyro_walk_ = {};
    accel_walk_ = {};
    barometer_bias_m_ = 0.0;
    barometer_walk_m_ = 0.0;
    estimated_attitude_ = {};
    sample_count_ = 0;
    estimate_initialized_ = false;
}

const ImuConfig &ImuSimulator::config() const {
    return config_;
}

ImuSample ImuSimulator::sample(const RigidBodyState &state) {
    const double dt = sample_dt(config_);
    const double sqrt_dt = std::sqrt(dt);
    const double white_scale = std::sqrt(1.0 / dt);
    const auto normal = [this](double stddev) {
        return stddev > 0.0 ? normal_(rng_) * stddev : 0.0;
    };
    const auto noise3 = [&normal](double stddev) {
        return Vec3{normal(stddev), normal(stddev), normal(stddev)};
    };

    gyro_bias_ = gyro_bias_ + noise3(config_.gyro_bias_drift_stddev * sqrt_dt);
    accel_bias_ = accel_bias_ + noise3(config_.accel_bias_drift_stddev * sqrt_dt);
    gyro_walk_ = gyro_walk_ + noise3(config_.gyro_random_walk_stddev * sqrt_dt);
    accel_walk_ = accel_walk_ + noise3(config_.accel_random_walk_stddev * sqrt_dt);
    barometer_bias_m_ += normal(config_.barometer_bias_drift_stddev_m * sqrt_dt);
    barometer_walk_m_ += normal(config_.barometer_random_walk_stddev_m * sqrt_dt);

    history_.push_back(state);
    const std::size_t delay = static_cast<std::size_t>(std::max(config_.delay_samples, 0));
    const std::size_t index = history_.size() > delay ? history_.size() - delay - 1 : 0;
    const RigidBodyState delayed = history_[index];
    while (history_.size() > delay + 1) {
        history_.pop_front();
    }

    const Vec3 gyro = delayed.angular_velocity +
            config_.gyro_bias +
            gyro_bias_ +
            gyro_walk_ +
            noise3(config_.gyro_noise_density * white_scale);
    const Vec3 accel = rotate(
            {-delayed.orientation.x, -delayed.orientation.y, -delayed.orientation.z, delayed.orientation.w},
            {0.0, config_.gravity_mps2, 0.0}) +
            config_.accel_bias +
            accel_bias_ +
            accel_walk_ +
            noise3(config_.accel_noise_density * white_scale);

    if (ideal_attitude_source(config_)) {
        estimated_attitude_ = normalized(delayed.orientation);
        estimate_initialized_ = true;
    } else if (!estimate_initialized_) {
        estimated_attitude_ = normalized(delayed.orientation);
        estimate_initialized_ = true;
    } else {
        estimated_attitude_ = integrate_gyro(estimated_attitude_, gyro, dt);
        const double gain = clamp_gain(config_.complementary_accel_gain);
        if (gain > 0.0 && std::isfinite(accel.x) && std::isfinite(accel.y) && std::isfinite(accel.z)) {
            const double accel_x = std::atan2(-accel.z, accel.y);
            const double accel_z = std::atan2(accel.x, accel.y);
            const double x = angle_x(estimated_attitude_) * (1.0 - gain) + accel_x * gain;
            const double y = angle_y(estimated_attitude_);
            const double z = angle_z(estimated_attitude_) * (1.0 - gain) + accel_z * gain;
            estimated_attitude_ = from_angles(x, y, z);
        }
    }

    const ImuSample sample{
            static_cast<double>(sample_count_) * dt,
            gyro,
            accel,
            delayed.position.y + barometer_bias_m_ + barometer_walk_m_ + normal(config_.barometer_noise_stddev_m),
            estimated_attitude_,
    };
    ++sample_count_;
    return sample;
}

} // namespace aerosim
