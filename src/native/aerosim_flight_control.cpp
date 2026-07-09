#include "aerosim_flight_control.hpp"

#include <algorithm>
#include <cmath>

namespace aerosim {
namespace {

constexpr double kPi = 3.14159265358979323846;

double radians(double degrees) {
    return degrees * kPi / 180.0;
}

double angle_x(const Quat &q) {
    return 2.0 * std::atan2(q.x, q.w);
}

double angle_z(const Quat &q) {
    return 2.0 * std::atan2(q.z, q.w);
}

double bounded_rate(double rate) {
    return std::clamp(rate, -6.0, 6.0);
}

double target_thrust_newtons(const SimulationConfig &config, double throttle) {
    if (config.hover_throttle <= 0.0) {
        return 0.0;
    }
    const double uncapped = config.mass_kg * config.gravity_mps2 * throttle / config.hover_throttle;
    return std::clamp(uncapped, 0.0, available_thrust_cap_newtons(config, throttle));
}

} // namespace

bool FlightController::arm(double throttle) {
    if (!std::isfinite(throttle) || throttle < 0.0) {
        arm_reject_code_ = "invalid_throttle";
        return false;
    }
    if (throttle > 0.05) {
        arm_reject_code_ = "throttle_not_low";
        return false;
    }
    armed_ = true;
    arm_reject_code_ = "";
    return true;
}

bool FlightController::armed() const {
    return armed_;
}

const std::string &FlightController::arm_reject_code() const {
    return arm_reject_code_;
}

void FlightController::reset_integrators() {
    ++integrator_reset_count_;
}

int FlightController::integrator_reset_count() const {
    return integrator_reset_count_;
}

TrajectorySample FlightController::step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command) {
    return step_angle_mode(state, clock, config, command, state.orientation);
}

TrajectorySample FlightController::step_angle_mode(
        RigidBodyState &state,
        SimulationClock &clock,
        const SimulationConfig &config,
        const FlightCommand &command,
        const Quat &estimated_attitude) {
    SimulationConfig frame_config = config;
    const double throttle = std::clamp(command.throttle, 0.0, 1.0);
    if (armed_) {
        const double target_thrust = target_thrust_newtons(frame_config, throttle);
        const double frame_dt = frame_config.physics_hz > 0 ? 1.0 / static_cast<double>(frame_config.physics_hz) : 0.0;
        motor_thrust_newtons_ = first_order_motor_response(
                motor_thrust_newtons_,
                target_thrust,
                frame_config.motor_tau_s,
                frame_dt);
        frame_config.total_thrust_newtons = motor_thrust_newtons_;
    } else {
        motor_thrust_newtons_ = 0.0;
        frame_config.total_thrust_newtons = 0.0;
    }
    if (armed_) {
        state.angular_velocity.x = bounded_rate((radians(command.pitch_degrees) - angle_x(estimated_attitude)) * 4.0);
        state.angular_velocity.y = radians(command.yaw_rate_degrees_per_second);
        state.angular_velocity.z = bounded_rate((radians(command.roll_degrees) - angle_z(estimated_attitude)) * 4.0);
    } else {
        state.angular_velocity = {};
    }
    return step_physics_frame(state, clock, frame_config);
}

void FlightController::reset_flight(RigidBodyState &state, SimulationClock &clock) {
    reset_integrators();
    motor_thrust_newtons_ = 0.0;
    state = {};
    clock = {};
}

} // namespace aerosim
