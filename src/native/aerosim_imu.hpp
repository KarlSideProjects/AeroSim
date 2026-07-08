#pragma once

#include "aerosim_simulation.hpp"

#include <cstdint>
#include <deque>
#include <random>

namespace aerosim {

struct ImuConfig {
    std::uint32_t seed = 1;
    double sample_hz = 240.0;
    std::int32_t delay_samples = 0;
    double gravity_mps2 = 9.80665;
    Vec3 gyro_bias;
    Vec3 accel_bias;
    double gyro_noise_density = 0.0;
    double accel_noise_density = 0.0;
    double gyro_bias_drift_stddev = 0.0;
    double accel_bias_drift_stddev = 0.0;
    double gyro_random_walk_stddev = 0.0;
    double accel_random_walk_stddev = 0.0;
    double barometer_noise_stddev_m = 0.0;
    double barometer_bias_drift_stddev_m = 0.0;
    double barometer_random_walk_stddev_m = 0.0;
    double complementary_accel_gain = 0.02;
};

struct ImuSample {
    double time_seconds = 0.0;
    Vec3 gyro_rad_per_s;
    Vec3 accel_mps2;
    double barometer_altitude_m = 0.0;
    Quat estimated_attitude;
};

class ImuSimulator {
private:
    ImuConfig config_;
    std::mt19937 rng_;
    std::normal_distribution<double> normal_;
    std::deque<RigidBodyState> history_;
    Vec3 gyro_bias_;
    Vec3 accel_bias_;
    Vec3 gyro_walk_;
    Vec3 accel_walk_;
    double barometer_bias_m_ = 0.0;
    double barometer_walk_m_ = 0.0;
    Quat estimated_attitude_;
    std::uint64_t sample_count_ = 0;
    bool estimate_initialized_ = false;

public:
    explicit ImuSimulator(const ImuConfig &config = {});

    void reset(std::uint32_t seed);
    const ImuConfig &config() const;
    ImuSample sample(const RigidBodyState &state);
};

} // namespace aerosim
