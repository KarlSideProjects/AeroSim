#pragma once

#include "aerosim_simulation.hpp"

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace aerosim {

enum class WindPreset {
    Light,
    Moderate,
    Severe,
};

enum class WindAxis {
    Longitudinal = 0,
    Lateral = 1,
    Vertical = 2,
};

struct WindConfig {
    Vec3 steady_wind_mps;
    Vec3 turbulence_sigma_mps;
    double reference_airspeed_mps = 30.0;
    double scale_length_m = 200.0;
    double shear_reference_height_m = 6.096;
    double shear_exponent = 1.0 / 7.0;
    bool shear_enabled = false;
    std::uint32_t seed = 1;
};

WindConfig wind_preset(WindPreset preset);
double dryden_psd_rad_s(const WindConfig &config, double omega_rad_s);
double dryden_psd_rad_s(const WindConfig &config, WindAxis axis, double omega_rad_s);
double dryden_filter_psd_rad_s(const WindConfig &config, WindAxis axis, double omega_rad_s, double sample_hz);

class DrydenSampler {
private:
    struct ShapingFilter {
        double b0 = 0.0;
        double b1 = 0.0;
        double b2 = 0.0;
        double a1 = 0.0;
        double a2 = 0.0;
        double x1 = 0.0;
        double x2 = 0.0;
        double y1 = 0.0;
        double y2 = 0.0;

        double step(double input);
    };

    struct AxisState {
        ShapingFilter filter;
        std::uint64_t rng_state = 0;
        double input_stddev = 1.0;
    };

    double sample_hz_ = 100.0;
    std::array<AxisState, 3> initial_axes_;
    std::array<AxisState, 3> axes_;
    mutable std::array<AxisState, 3> sample_at_axes_;
    mutable bool sample_at_ready_ = false;
    mutable std::int64_t sample_at_next_index_ = 0;
    mutable Vec3 sample_at_value_;

    static AxisState make_axis(const WindConfig &config, WindAxis axis, double sample_hz);
    static double unit_noise(std::uint64_t &state);
    static Vec3 step_axes(std::array<AxisState, 3> &axes);
    void reset_sample_at() const;

public:
    DrydenSampler(const WindConfig &config, double sample_hz);
    Vec3 sample();
    Vec3 sample_at(double time_seconds) const;
};

class WindField {
private:
    WindConfig config_;
    std::unique_ptr<DrydenSampler> dryden_;

public:
    void configure(const WindConfig &config);
    const WindConfig &config() const;
    void set_steady_wind(const Vec3 &wind);
    Vec3 steady_wind() const;
    Vec3 sample(double time_seconds, const Vec3 &position) const;
};

} // namespace aerosim
