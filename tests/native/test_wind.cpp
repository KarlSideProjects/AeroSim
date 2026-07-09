#include "aerosim_wind.hpp"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

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

bool same_vec_bits(const aerosim::Vec3 &a, const aerosim::Vec3 &b) {
    return same_bits(a.x, b.x) && same_bits(a.y, b.y) && same_bits(a.z, b.z);
}

double welch_psd_rad_s(const std::vector<double> &samples, double sample_hz, int bin) {
    constexpr int kSegmentLength = 1 << 14;
    constexpr int kHop = kSegmentLength / 2;
    constexpr double kPi = 3.14159265358979323846;
    double window_power = 0.0;
    std::vector<double> window(kSegmentLength);
    for (int i = 0; i < kSegmentLength; ++i) {
        window[static_cast<std::size_t>(i)] = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(i) / static_cast<double>(kSegmentLength));
        window_power += window[static_cast<std::size_t>(i)] * window[static_cast<std::size_t>(i)];
    }

    double total = 0.0;
    int segments = 0;
    for (std::size_t start = 0; start + kSegmentLength <= samples.size(); start += kHop) {
        const double step = 2.0 * kPi * static_cast<double>(bin) / static_cast<double>(kSegmentLength);
        const double cos_step = std::cos(step);
        const double sin_step = std::sin(step);
        double cos_value = 1.0;
        double sin_value = 0.0;
        double real = 0.0;
        double imag = 0.0;
        for (int i = 0; i < kSegmentLength; ++i) {
            const double value = samples[start + static_cast<std::size_t>(i)] * window[static_cast<std::size_t>(i)];
            real += value * cos_value;
            imag -= value * sin_value;
            const double next_cos = cos_value * cos_step - sin_value * sin_step;
            const double next_sin = sin_value * cos_step + cos_value * sin_step;
            cos_value = next_cos;
            sin_value = next_sin;
        }
        total += 2.0 * (real * real + imag * imag) / (sample_hz * window_power) / (2.0 * kPi);
        ++segments;
    }
    return total / static_cast<double>(segments);
}

double axis_value(const aerosim::Vec3 &value, aerosim::WindAxis axis) {
    switch (axis) {
        case aerosim::WindAxis::Longitudinal:
            return value.x;
        case aerosim::WindAxis::Lateral:
            return value.y;
        case aerosim::WindAxis::Vertical:
            return value.z;
    }
    return 0.0;
}

double chi_square_quantile_wilson_hilferty(double dof, double z) {
    const double term = 1.0 - 2.0 / (9.0 * dof) + z * std::sqrt(2.0 / (9.0 * dof));
    return dof * term * term * term;
}

} // namespace

int main() {
    aerosim::WindField wind;
    wind.set_steady_wind({1.25, -2.5, 0.75});
    const aerosim::Vec3 sample = wind.sample(0.0, {});
    if (!near(sample.x, 1.25, 0.0) ||
            !near(sample.y, -2.5, 0.0) ||
            !near(sample.z, 0.75, 0.0)) {
        return fail("steady wind vector must be configurable and observable through the wind field sample");
    }

    const aerosim::WindConfig light = aerosim::wind_preset(aerosim::WindPreset::Light);
    const aerosim::WindConfig moderate = aerosim::wind_preset(aerosim::WindPreset::Moderate);
    const aerosim::WindConfig severe = aerosim::wind_preset(aerosim::WindPreset::Severe);
    if (!(light.turbulence_sigma_mps.x > 0.0 &&
                light.turbulence_sigma_mps.x < moderate.turbulence_sigma_mps.x &&
                moderate.turbulence_sigma_mps.x < severe.turbulence_sigma_mps.x)) {
        return fail("wind presets must expose increasing MIL-style turbulence intensity levels");
    }
    wind.configure(moderate);
    if (!near(wind.config().turbulence_sigma_mps.x, moderate.turbulence_sigma_mps.x, 0.0) ||
            !near(wind.config().reference_airspeed_mps, moderate.reference_airspeed_mps, 0.0)) {
        return fail("wind field must retain the selected preset configuration");
    }
    const aerosim::Vec3 same_time_a = wind.sample(1.25, {0.0, 6.096, 0.0});
    const aerosim::Vec3 same_time_b = wind.sample(1.25, {0.0, 6.096, 0.0});
    const aerosim::Vec3 later_time = wind.sample(1.26, {0.0, 6.096, 0.0});
    if (!same_vec_bits(same_time_a, same_time_b) || same_vec_bits(same_time_a, later_time)) {
        return fail("public wind field samples must include deterministic time-varying Dryden turbulence");
    }
    aerosim::WindConfig alternate_seed = moderate;
    alternate_seed.seed = moderate.seed + 1U;
    wind.configure(alternate_seed);
    const aerosim::Vec3 alternate_seed_sample = wind.sample(1.25, {0.0, 6.096, 0.0});
    if (same_vec_bits(same_time_a, alternate_seed_sample)) {
        return fail("public wind field samples must use the configured Dryden seed");
    }

    aerosim::WindConfig shear_config;
    shear_config.steady_wind_mps = {8.0, 0.0, 0.0};
    shear_config.shear_enabled = true;
    wind.configure(shear_config);
    for (const double height_m : {6.096, 15.0, 30.0, 100.0}) {
        const double expected = 8.0 * std::pow(height_m / 6.096, 1.0 / 7.0);
        const double actual = wind.sample(0.0, {0.0, height_m, 0.0}).x;
        if (!near(actual, expected, expected * 0.05)) {
            return fail("G3.5 wind shear profile must match the MIL-style 1/7 power-law model within 5%");
        }
    }

    aerosim::SimulationConfig wind_drift_config;
    wind_drift_config.seconds = 1.0;
    wind_drift_config.physics_hz = 240;
    wind_drift_config.substep_hz = 1000;
    wind_drift_config.total_thrust_newtons = wind_drift_config.mass_kg * wind_drift_config.gravity_mps2;
    wind_drift_config.wind_mps = {3.0, 0.0, -1.0};
    const auto wind_drift = aerosim::simulate_trajectory(wind_drift_config);
    if (wind_drift.empty() ||
            !near(wind_drift.back().state.position.x, 3.0, 0.01) ||
            !near(wind_drift.back().state.position.z, -1.0, 0.01)) {
        return fail("configured wind must perturb the C++ flight trajectory, not only the sampling API");
    }

    aerosim::DrydenSampler dryden_a(moderate, 100.0);
    aerosim::DrydenSampler dryden_b(moderate, 100.0);
    bool saw_axis_independence = false;
    for (int i = 0; i < 4096; ++i) {
        const aerosim::Vec3 a = dryden_a.sample();
        const aerosim::Vec3 b = dryden_b.sample();
        if (!same_bits(a.x, b.x) || !same_bits(a.y, b.y) || !same_bits(a.z, b.z)) {
            return fail("G3.4 same Dryden seed and preset must produce bitwise-identical samples");
        }
        saw_axis_independence = saw_axis_independence || !same_bits(a.x, a.y) || !same_bits(a.x, a.z);
    }
    if (!saw_axis_independence) {
        return fail("G3.4 Dryden turbulence axes must not reuse the same shaped signal");
    }

    aerosim::WindConfig anisotropic = moderate;
    anisotropic.turbulence_sigma_mps = {1.0, 2.0, 3.0};
    aerosim::DrydenSampler anisotropic_sampler(anisotropic, 100.0);
    const aerosim::Vec3 anisotropic_sample = anisotropic_sampler.sample();
    if (same_bits(anisotropic_sample.x, anisotropic_sample.y) ||
            same_bits(anisotropic_sample.x, anisotropic_sample.z) ||
            same_bits(anisotropic_sample.y, anisotropic_sample.z)) {
        return fail("G3.4 Dryden axes must be independently shaped, not scalar multiples of one unit signal");
    }

    constexpr int kSegmentLength = 1 << 14;
    constexpr double kSampleHz = 100.0;
    constexpr double kPi = 3.14159265358979323846;
    for (const aerosim::WindPreset preset : {
                 aerosim::WindPreset::Light,
                 aerosim::WindPreset::Moderate,
                 aerosim::WindPreset::Severe,
         }) {
        const aerosim::WindConfig config = aerosim::wind_preset(preset);
        for (const aerosim::WindAxis axis : {
                     aerosim::WindAxis::Longitudinal,
                     aerosim::WindAxis::Lateral,
                     aerosim::WindAxis::Vertical,
             }) {
            aerosim::DrydenSampler sampler(config, kSampleHz);
            const double domega = 2.0 * kPi * kSampleHz / static_cast<double>(kSegmentLength);
            const int first_bin = static_cast<int>(std::ceil(0.1 / domega));
            const int last_bin = static_cast<int>(std::floor(10.0 / domega));
            for (int bin = first_bin; bin <= last_bin; ++bin) {
                const double omega = static_cast<double>(bin) * domega;
                const double expected = aerosim::dryden_psd_rad_s(config, axis, omega);
                const double actual = aerosim::dryden_filter_psd_rad_s(config, axis, omega, kSampleHz);
                if (!near(actual, expected, expected * 0.10)) {
                    std::cerr << "analytic bin=" << bin << " omega=" << omega << " actual=" << actual << " expected=" << expected << "\n";
                    return fail("G3.4 Dryden shaping-filter transfer function must match the theoretical spectrum within 10% for every 0.1-10 rad/s bin on every axis");
                }
            }

            for (int i = 0; i < kSegmentLength; ++i) {
                sampler.sample();
            }
            std::vector<double> samples(kSegmentLength * 4);
            for (double &sample : samples) {
                sample = axis_value(sampler.sample(), axis);
            }
            double ratio_total = 0.0;
            int checked_bins = 0;
            for (int bin = first_bin; bin <= last_bin; bin += 8) {
                const double omega = static_cast<double>(bin) * domega;
                const double expected = aerosim::dryden_psd_rad_s(config, axis, omega);
                const double actual = welch_psd_rad_s(samples, kSampleHz, bin);
                ratio_total += actual / expected;
                ++checked_bins;
            }
            const double ratio = ratio_total / static_cast<double>(checked_bins);
            const double segments = 1.0 + 2.0 * (static_cast<double>(samples.size()) / static_cast<double>(kSegmentLength) - 1.0);
            const double dof = 2.0 * segments;
            const double lower_95 = chi_square_quantile_wilson_hilferty(dof, -1.96) / dof;
            const double upper_95 = chi_square_quantile_wilson_hilferty(dof, 1.96) / dof;
            if (ratio < lower_95 || ratio > upper_95) {
                std::cerr << "welch ratio=" << ratio << " lower_95=" << lower_95 << " upper_95=" << upper_95 << "\n";
                return fail("G3.4 Dryden Welch PSD smoke must stay inside a conservative 95% CI");
            }
        }
    }

    return EXIT_SUCCESS;
}
