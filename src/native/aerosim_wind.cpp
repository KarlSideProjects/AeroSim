#include "aerosim_wind.hpp"

#include <algorithm>
#include <cmath>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

struct FilterCoefficients {
    double b0 = 0.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a1 = 0.0;
    double a2 = 0.0;
};

double finite_or(double value, double fallback) {
    return std::isfinite(value) ? value : fallback;
}

std::size_t axis_index(WindAxis axis) {
    return static_cast<std::size_t>(axis);
}

double axis_sigma(const WindConfig &config, WindAxis axis) {
    switch (axis) {
        case WindAxis::Longitudinal:
            return std::max(0.0, config.turbulence_sigma_mps.x);
        case WindAxis::Lateral:
            return std::max(0.0, config.turbulence_sigma_mps.y);
        case WindAxis::Vertical:
            return std::max(0.0, config.turbulence_sigma_mps.z);
    }
    return 0.0;
}

double splitmix_unit(std::uint64_t &state) {
    state += 0x9e3779b97f4a7c15ULL;
    std::uint64_t value = state;
    value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
    value ^= value >> 31U;
    return static_cast<double>(value >> 11U) * 0x1.0p-53;
}

std::uint64_t seeded_state(std::uint32_t seed, WindAxis axis) {
    std::uint64_t state = (static_cast<std::uint64_t>(seed) << 32U) ^
            (0xd1b54a32d192ed03ULL + 0x9e3779b97f4a7c15ULL * (axis_index(axis) + 1U));
    splitmix_unit(state);
    return state;
}

FilterCoefficients dryden_filter(const WindConfig &config, WindAxis axis, double sample_hz) {
    const double hz = std::max(1e-9, finite_or(sample_hz, 100.0));
    const double airspeed = std::max(1e-9, finite_or(config.reference_airspeed_mps, 30.0));
    const double scale = std::max(1e-9, finite_or(config.scale_length_m, 200.0));
    const double sigma = axis_sigma(config, axis);
    const double gain = sigma * std::sqrt(2.0 * scale / (kPi * airspeed));
    const double bilinear = 2.0 * hz;

    FilterCoefficients filter;
    if (axis == WindAxis::Longitudinal) {
        const double tau = scale / airspeed;
        const double denom = 1.0 + tau * bilinear;
        filter.b0 = gain / denom;
        filter.b1 = gain / denom;
        filter.a1 = (1.0 - tau * bilinear) / denom;
        return filter;
    }

    const double tau = 2.0 * scale / airspeed;
    const double a = 1.0 + tau * bilinear;
    const double b = 1.0 - tau * bilinear;
    const double c = std::sqrt(3.0) * tau * bilinear;
    const double denom = a * a;
    filter.b0 = gain * (1.0 + c) / denom;
    filter.b1 = gain * 2.0 / denom;
    filter.b2 = gain * (1.0 - c) / denom;
    filter.a1 = 2.0 * a * b / denom;
    filter.a2 = b * b / denom;
    return filter;
}

double filter_psd_rad_s(const FilterCoefficients &filter, double omega_rad_s, double sample_hz) {
    const double hz = std::max(1e-9, finite_or(sample_hz, 100.0));
    const double theta = std::max(0.0, omega_rad_s) / hz;
    const double c1 = std::cos(theta);
    const double s1 = std::sin(theta);
    const double c2 = std::cos(2.0 * theta);
    const double s2 = std::sin(2.0 * theta);
    const double num_re = filter.b0 + filter.b1 * c1 + filter.b2 * c2;
    const double num_im = -filter.b1 * s1 - filter.b2 * s2;
    const double den_re = 1.0 + filter.a1 * c1 + filter.a2 * c2;
    const double den_im = -filter.a1 * s1 - filter.a2 * s2;
    const double den_power = den_re * den_re + den_im * den_im;
    if (den_power <= 0.0) {
        return 0.0;
    }
    return (num_re * num_re + num_im * num_im) / den_power;
}

} // namespace

WindConfig wind_preset(WindPreset preset) {
    WindConfig config;
    switch (preset) {
        case WindPreset::Light:
            config.turbulence_sigma_mps = {0.5, 0.5, 0.5};
            break;
        case WindPreset::Moderate:
            config.turbulence_sigma_mps = {1.5, 1.5, 1.5};
            break;
        case WindPreset::Severe:
            config.turbulence_sigma_mps = {3.0, 3.0, 3.0};
            break;
    }
    return config;
}

double dryden_psd_rad_s(const WindConfig &config, double omega_rad_s) {
    return dryden_psd_rad_s(config, WindAxis::Longitudinal, omega_rad_s);
}

double dryden_psd_rad_s(const WindConfig &config, WindAxis axis, double omega_rad_s) {
    const double sigma = axis_sigma(config, axis);
    const double airspeed = std::max(1e-9, config.reference_airspeed_mps);
    const double scale = std::max(1e-9, config.scale_length_m);
    const double ratio = scale * std::max(0.0, omega_rad_s) / airspeed;
    if (axis == WindAxis::Longitudinal) {
        return sigma * sigma * (2.0 * scale / (kPi * airspeed)) / (1.0 + ratio * ratio);
    }
    const double two_ratio = 2.0 * ratio;
    return sigma * sigma * (2.0 * scale / (kPi * airspeed)) *
            (1.0 + 3.0 * two_ratio * two_ratio) /
            ((1.0 + two_ratio * two_ratio) * (1.0 + two_ratio * two_ratio));
}

double dryden_filter_psd_rad_s(const WindConfig &config, WindAxis axis, double omega_rad_s, double sample_hz) {
    return filter_psd_rad_s(dryden_filter(config, axis, sample_hz), omega_rad_s, sample_hz);
}

double DrydenSampler::ShapingFilter::step(double input) {
    const double output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = input;
    y2 = y1;
    y1 = output;
    return output;
}

DrydenSampler::AxisState DrydenSampler::make_axis(const WindConfig &config, WindAxis axis, double sample_hz) {
    const FilterCoefficients coefficients = dryden_filter(config, axis, sample_hz);
    ShapingFilter filter;
    filter.b0 = coefficients.b0;
    filter.b1 = coefficients.b1;
    filter.b2 = coefficients.b2;
    filter.a1 = coefficients.a1;
    filter.a2 = coefficients.a2;
    return {filter, seeded_state(config.seed, axis), std::sqrt(kPi * std::max(1e-9, finite_or(sample_hz, 100.0)))};
}

double DrydenSampler::unit_noise(std::uint64_t &state) {
    double sum = 0.0;
    for (int i = 0; i < 12; ++i) {
        sum += splitmix_unit(state);
    }
    return sum - 6.0;
}

Vec3 DrydenSampler::step_axes(std::array<AxisState, 3> &axes) {
    std::array<double, 3> values{};
    for (std::size_t axis = 0; axis < axes.size(); ++axis) {
        AxisState &state = axes[axis];
        values[axis] = state.filter.step(unit_noise(state.rng_state) * state.input_stddev);
    }
    return {values[0], values[1], values[2]};
}

void DrydenSampler::reset_sample_at() const {
    sample_at_axes_ = initial_axes_;
    sample_at_ready_ = false;
    sample_at_next_index_ = 0;
    sample_at_value_ = {};
}

DrydenSampler::DrydenSampler(const WindConfig &config, double sample_hz) :
        sample_hz_(std::max(1e-9, finite_or(sample_hz, 100.0))) {
    for (const WindAxis axis : {WindAxis::Longitudinal, WindAxis::Lateral, WindAxis::Vertical}) {
        initial_axes_[axis_index(axis)] = make_axis(config, axis, sample_hz_);
    }
    axes_ = initial_axes_;
    reset_sample_at();
}

Vec3 DrydenSampler::sample() {
    return step_axes(axes_);
}

Vec3 DrydenSampler::sample_at(double time_seconds) const {
    const double time = std::max(0.0, finite_or(time_seconds, 0.0));
    const std::int64_t target_index = static_cast<std::int64_t>(std::floor(time * sample_hz_));
    if (target_index < sample_at_next_index_ - 1) {
        reset_sample_at();
    }
    while (!sample_at_ready_ || sample_at_next_index_ <= target_index) {
        sample_at_value_ = step_axes(sample_at_axes_);
        sample_at_ready_ = true;
        ++sample_at_next_index_;
    }
    return sample_at_value_;
}

void WindField::configure(const WindConfig &config) {
    config_ = config;
    dryden_ = std::make_unique<DrydenSampler>(config_, 100.0);
}

const WindConfig &WindField::config() const {
    return config_;
}

void WindField::set_steady_wind(const Vec3 &wind) {
    config_.steady_wind_mps = wind;
}

Vec3 WindField::steady_wind() const {
    return config_.steady_wind_mps;
}

Vec3 WindField::sample(double time_seconds, const Vec3 &position) const {
    Vec3 wind = config_.steady_wind_mps;
    if (config_.shear_enabled &&
            config_.shear_reference_height_m > 0.0 &&
            config_.shear_exponent != 0.0) {
        const double height = std::max(position.y, config_.shear_reference_height_m);
        const double scale = std::pow(height / config_.shear_reference_height_m, config_.shear_exponent);
        wind.x *= scale;
        wind.z *= scale;
    }
    if (dryden_) {
        const Vec3 turbulence = dryden_->sample_at(time_seconds);
        wind.x += turbulence.x;
        wind.y += turbulence.y;
        wind.z += turbulence.z;
    }
    return wind;
}

} // namespace aerosim
