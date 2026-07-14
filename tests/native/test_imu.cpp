#include "aerosim_imu.hpp"
#include "aerosim_flight_control.hpp"

#include <array>
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

void configure_power_model(aerosim::SimulationConfig &config) {
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = config.mass_kg * config.gravity_mps2 * 2.0;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.battery_cell_resistance_ohm = 0.0;
    config.max_total_current_a = 1.0;
    config.per_motor.inertia_kg_m2 = {0.003, 0.003, 0.005};
    config.per_motor.max_thrust_per_motor_newtons = config.max_total_thrust_newtons / 4.0;
    config.per_motor.max_current_per_motor_a = 0.25;
    config.per_motor.yaw_torque_per_newton = 0.01;
    config.per_motor.position_frd = {{
            {-0.1125, 0.1125, 0.0},
            {0.1125, 0.1125, 0.0},
            {-0.1125, -0.1125, 0.0},
            {0.1125, -0.1125, 0.0},
    }};
    config.per_motor.spin_direction = {{1.0, -1.0, -1.0, 1.0}};
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

    aerosim::ImuSimulator ideal_imu({});
    ideal_imu.sample({});
    aerosim::RigidBodyState tilted_ideal_state;
    const double ideal_tilt = 12.0 * 3.14159265358979323846 / 180.0;
    tilted_ideal_state.orientation.x = std::sin(ideal_tilt * 0.5);
    tilted_ideal_state.orientation.w = std::cos(ideal_tilt * 0.5);
    const aerosim::ImuSample ideal_sample = ideal_imu.sample(tilted_ideal_state);
    if (!near(ideal_sample.estimated_attitude.x, tilted_ideal_state.orientation.x, 1e-12) ||
            !near(ideal_sample.estimated_attitude.w, tilted_ideal_state.orientation.w, 1e-12)) {
        return fail("zero-error IMU attitude estimate must follow the observed orientation without estimator lag");
    }

    aerosim::SimulationConfig sim_config;
    sim_config.physics_hz = 100;
    sim_config.substep_hz = 100;
    configure_power_model(sim_config);

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

    aerosim::ImuConfig bias_config;
    bias_config.gyro_bias = {0.10, -0.20, 0.30};
    bias_config.accel_bias = {1.0, 2.0, 3.0};
    aerosim::ImuSimulator biased_imu(bias_config);
    const aerosim::ImuSample biased = biased_imu.sample({});
    if (!near(biased.gyro_rad_per_s.x, 0.10, 0.0) ||
            !near(biased.gyro_rad_per_s.y, -0.20, 0.0) ||
            !near(biased.gyro_rad_per_s.z, 0.30, 0.0)) {
        return fail("constant gyro bias must be visible in zero-noise IMU samples");
    }
    if (!near(biased.accel_mps2.x, 1.0, 0.0) ||
            !near(biased.accel_mps2.y, bias_config.gravity_mps2 + 2.0, 1e-12) ||
            !near(biased.accel_mps2.z, 3.0, 0.0)) {
        return fail("constant accel bias must be visible in zero-noise IMU samples");
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

    aerosim::ImuConfig psd_config;
    psd_config.seed = 88;
    psd_config.sample_hz = 200.0;
    psd_config.gyro_noise_density = 0.03;
    constexpr int kPsdSamples = 2048;
    std::array<double, kPsdSamples> gyro_samples{};
    aerosim::ImuSimulator psd_imu(psd_config);
    Stats psd_stats;
    for (double &sample : gyro_samples) {
        sample = psd_imu.sample({}).gyro_rad_per_s.x;
        psd_stats.add(sample);
    }
    const auto band_power = [&gyro_samples, mean = psd_stats.mean](int first_bin, int last_bin) {
        constexpr double kPi = 3.14159265358979323846;
        double total = 0.0;
        int bins = 0;
        for (int bin = first_bin; bin <= last_bin; ++bin) {
            double real = 0.0;
            double imag = 0.0;
            for (int index = 0; index < kPsdSamples; ++index) {
                const double centered = gyro_samples[static_cast<std::size_t>(index)] - mean;
                const double angle = 2.0 * kPi * static_cast<double>(bin * index) / static_cast<double>(kPsdSamples);
                real += centered * std::cos(angle);
                imag -= centered * std::sin(angle);
            }
            total += (real * real + imag * imag) / static_cast<double>(kPsdSamples);
            ++bins;
        }
        return total / static_cast<double>(bins);
    };
    const double low_band = band_power(2, 17);
    const double high_band = band_power(160, 175);
    const double psd_ratio = low_band / high_band;
    if (!std::isfinite(psd_ratio) || psd_ratio < 0.25 || psd_ratio > 4.0) {
        return fail("gyro white-noise PSD must stay broadly flat across low and high frequency bands");
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
