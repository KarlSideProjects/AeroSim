#pragma once

#include <cstdint>

#include "aerosim_flight_control.hpp"
#include "aerosim_simulation.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

class AeroSimNative : public godot::RefCounted {
    GDCLASS(AeroSimNative, godot::RefCounted)

protected:
    static void _bind_methods();

private:
    aerosim::RigidBodyState simulation_state_;
    aerosim::SimulationClock simulation_clock_;
    aerosim::FlightController flight_controller_;

public:
    std::int32_t probe_value() const;
    std::int32_t trajectory_stride() const;
    void reset_simulation();
    godot::PackedFloat64Array step_simulation(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons);
    bool arm_flight_control(double throttle);
    bool flight_control_armed() const;
    godot::String flight_control_arm_reject_code() const;
    void reset_flight();
    godot::PackedFloat64Array step_angle_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double throttle,
            double roll_degrees,
            double pitch_degrees,
            double yaw_rate_degrees_per_second);
    godot::PackedFloat64Array simulate_trajectory(
            double seconds,
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons) const;
};
