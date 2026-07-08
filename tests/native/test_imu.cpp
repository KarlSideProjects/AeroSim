#include "aerosim_imu.hpp"
#include "aerosim_flight_control.hpp"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>

namespace {

int fail(const char *message) {
    std::cerr << message << "\n";
    return EXIT_FAILURE;
}

bool near(double actual, double expected, double tolerance) {
    return std::abs(actual - expected) <= tolerance;
}

bool same_bits(double a, double b) {
    return std::memcmp(&a, &b, sizeof(double)) == 0;
}

struct Stats {
    int count = 0;
    double mean = 0.0;
    double m2 = 0.0;

    void add(double value) {
        ++count;
        const double delta = value - mean;
        mean += delta / static_cast<double>(count);
        m2 += delta * (value - mean);
    }

    double variance() const {
        return count > 1 ? m2 / static_cast<double>(count - 1) : 0.0;
    }
};

} // namespace

int main() {
    aerosim::ImuConfig config;
    config.seed = 1234;
    config.sample_hz = 100.0;
    config.delay_samples = 2;

    aerosim::ImuSimulator imu(config);
    aerosim::RigidBodyState state;
    state.angular_velocity = {1.0, 2.0, 3.0};

    imu.sample(state);
    state.angular_velocity = {4.0, 5.0, 6.0};
    imu.sample(state);
    state.angular_velocity = {7.0, 8.0, 9.0};
    const aerosim::ImuSample delayed = imu.sample(state);

    if (!near(delayed.gyro_rad_per_s.x, 1.0, 0.0) ||
            !near(delayed.gyro_rad_per_s.y, 2.0, 0.0) ||
            !near(delayed.gyro_rad_per_s.z, 3.0, 0.0)) {
        return fail("IMU delay must expose the configured number of prior gyro samples");
    }
    if (!near(delayed.accel_mps2.y, 9.80665, 1e-12)) {
        return fail("zero-noise level IMU must expose gravity as body-frame acceleration");
    }
    if (!near(aerosim::quat_norm(delayed.estimated_attitude), 1.0, 1e-12)) {
        return fail("IMU attitude estimate must stay normalized");
    }

    aerosim::SimulationConfig sim_config;
    sim_config.physics_hz = 100;
    sim_config.substep_hz = 100;

    aerosim::FlightController controller;
    if (!controller.arm(0.0)) {
        return fail("IMU flight-control test setup should arm from low throttle");
    }

    aerosim::RigidBodyState tilted_state;
    const double ten_degrees = 10.0 * 3.14159265358979323846 / 180.0;
    tilted_state.orientation.x = std::sin(ten_degrees * 0.5);
    tilted_state.orientation.w = std::cos(ten_degrees * 0.5);
    aerosim::SimulationClock clock;
    aerosim::FlightCommand hover;
    hover.throttle = 0.5;
    controller.step_angle_mode(tilted_state, clock, sim_config, hover, aerosim::Quat{});
    if (!near(tilted_state.angular_velocity.x, 0.0, 1e-12)) {
        return fail("Angle Mode must use IMU estimated attitude instead of true body attitude");
    }

    aerosim::ImuConfig deterministic_config;
    deterministic_config.seed = 99;
    deterministic_config.sample_hz = 200.0;
    deterministic_config.delay_samples = 1;
    deterministic_config.gyro_noise_density = 0.01;
    deterministic_config.accel_noise_density = 0.20;
    deterministic_config.gyro_bias_drift_stddev = 0.03;
    deterministic_config.accel_random_walk_stddev = 0.04;
    deterministic_config.barometer_noise_stddev_m = 0.10;
    aerosim::ImuSimulator first_imu(deterministic_config);
    aerosim::ImuSimulator second_imu(deterministic_config);
    for (int i = 0; i < 64; ++i) {
        aerosim::RigidBodyState moving;
        moving.position.y = static_cast<double>(i) * 0.1;
        moving.angular_velocity = {
                0.01 * static_cast<double>(i),
                -0.02 * static_cast<double>(i),
                0.03 * static_cast<double>(i),
        };
        const aerosim::ImuSample a = first_imu.sample(moving);
        const aerosim::ImuSample b = second_imu.sample(moving);
        if (!same_bits(a.gyro_rad_per_s.x, b.gyro_rad_per_s.x) ||
                !same_bits(a.accel_mps2.y, b.accel_mps2.y) ||
                !same_bits(a.barometer_altitude_m, b.barometer_altitude_m) ||
                !same_bits(a.estimated_attitude.w, b.estimated_attitude.w)) {
            return fail("same IMU seed and input stream must produce bitwise-identical samples");
        }
    }
    first_imu.reset(123);
    second_imu.reset(123);
    const aerosim::ImuSample reset_a = first_imu.sample({});
    const aerosim::ImuSample reset_b = second_imu.sample({});
    if (!same_bits(reset_a.gyro_rad_per_s.x, reset_b.gyro_rad_per_s.x) ||
            !same_bits(reset_a.accel_mps2.x, reset_b.accel_mps2.x)) {
        return fail("resetting IMUs to the same seed must restore the deterministic stream");
    }

    aerosim::ImuConfig noise_config;
    noise_config.seed = 7;
    noise_config.sample_hz = 100.0;
    noise_config.gyro_noise_density = 0.02;
    noise_config.accel_noise_density = 0.40;
    noise_config.barometer_noise_stddev_m = 0.10;
    noise_config.complementary_accel_gain = 0.0;
    aerosim::ImuSimulator noisy_imu(noise_config);
    Stats gyro_x;
    Stats accel_x;
    Stats barometer;
    Stats gyro_x_allan;
    bool have_previous_gyro = false;
    double previous_gyro = 0.0;
    for (int i = 0; i < 20000; ++i) {
        const aerosim::ImuSample sample = noisy_imu.sample({});
        gyro_x.add(sample.gyro_rad_per_s.x);
        accel_x.add(sample.accel_mps2.x);
        barometer.add(sample.barometer_altitude_m);
        if (have_previous_gyro) {
            const double delta = sample.gyro_rad_per_s.x - previous_gyro;
            gyro_x_allan.add(0.5 * delta * delta);
        }
        previous_gyro = sample.gyro_rad_per_s.x;
        have_previous_gyro = true;
    }
    const double expected_gyro_variance = noise_config.gyro_noise_density *
            noise_config.gyro_noise_density *
            noise_config.sample_hz;
    const double expected_accel_variance = noise_config.accel_noise_density *
            noise_config.accel_noise_density *
            noise_config.sample_hz;
    if (!near(gyro_x.mean, 0.0, 0.02) ||
            !near(gyro_x.variance(), expected_gyro_variance, expected_gyro_variance * 0.20)) {
        return fail("gyro noise density must set zero-mean sample variance");
    }
    if (!near(accel_x.mean, 0.0, 0.30) ||
            !near(accel_x.variance(), expected_accel_variance, expected_accel_variance * 0.20)) {
        return fail("accel noise density must set zero-mean sample variance");
    }
    if (!near(barometer.mean, 0.0, 0.01) ||
            !near(barometer.variance(), noise_config.barometer_noise_stddev_m * noise_config.barometer_noise_stddev_m, 0.01)) {
        return fail("barometer noise must set zero-mean altitude variance");
    }
    if (!near(gyro_x_allan.mean, expected_gyro_variance, expected_gyro_variance * 0.25)) {
        return fail("gyro Allan variance at one sample must match configured white-noise density");
    }

    aerosim::ImuConfig drift_config;
    drift_config.seed = 42;
    drift_config.sample_hz = 100.0;
    drift_config.gyro_bias_drift_stddev = 0.50;
    aerosim::ImuSimulator drifting_imu(drift_config);
    Stats early_bias;
    Stats late_bias;
    for (int i = 0; i < 4000; ++i) {
        const double value = drifting_imu.sample({}).gyro_rad_per_s.x;
        if (i < 500) {
            early_bias.add(value);
        }
        if (i >= 3500) {
            late_bias.add(value);
        }
    }
    if (std::abs(late_bias.mean - early_bias.mean) < 0.10) {
        return fail("gyro bias drift must move the measured mean over time");
    }

    aerosim::ImuConfig walk_config;
    walk_config.seed = 314;
    walk_config.sample_hz = 100.0;
    walk_config.gyro_random_walk_stddev = 0.50;
    walk_config.accel_random_walk_stddev = 0.50;
    aerosim::ImuSimulator walking_imu(walk_config);
    Stats early_gyro_walk;
    Stats late_gyro_walk;
    Stats early_walk;
    Stats late_walk;
    for (int i = 0; i < 4000; ++i) {
        const aerosim::ImuSample sample = walking_imu.sample({});
        const double gyro_value = sample.gyro_rad_per_s.x;
        const double value = sample.accel_mps2.x;
        if (i < 500) {
            early_gyro_walk.add(gyro_value);
            early_walk.add(value);
        }
        if (i >= 3500) {
            late_gyro_walk.add(gyro_value);
            late_walk.add(value);
        }
    }
    if (std::abs(late_gyro_walk.mean - early_gyro_walk.mean) < 0.10) {
        return fail("gyro random walk must move the measured mean over time");
    }
    if (std::abs(late_walk.mean - early_walk.mean) < 0.10) {
        return fail("accel random walk must move the measured mean over time");
    }

    aerosim::ImuConfig accel_drift_config;
    accel_drift_config.seed = 2718;
    accel_drift_config.sample_hz = 100.0;
    accel_drift_config.accel_bias_drift_stddev = 0.50;
    aerosim::ImuSimulator accel_drifting_imu(accel_drift_config);
    Stats early_accel_bias;
    Stats late_accel_bias;
    for (int i = 0; i < 4000; ++i) {
        const double value = accel_drifting_imu.sample({}).accel_mps2.x;
        if (i < 500) {
            early_accel_bias.add(value);
        }
        if (i >= 3500) {
            late_accel_bias.add(value);
        }
    }
    if (std::abs(late_accel_bias.mean - early_accel_bias.mean) < 0.10) {
        return fail("accel bias drift must move the measured mean over time");
    }

    return EXIT_SUCCESS;
}
