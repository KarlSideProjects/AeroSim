#pragma once

#include <cstdint>

#include "aerosim_collision.hpp"
#include "aerosim_flight_control.hpp"
#include "aerosim_imu.hpp"
#include "aerosim_simulation.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

class AeroSimNative : public godot::RefCounted {
    GDCLASS(AeroSimNative, godot::RefCounted)

protected:
    static void _bind_methods();

private:
    aerosim::RigidBodyState simulation_state_;
    aerosim::SimulationClock simulation_clock_;
    aerosim::HardwareConfig hardware_config_;
    aerosim::FlightController flight_controller_;
    aerosim::CollisionAuthoritySwitch collision_authority_;
    aerosim::ImuConfig imu_config_;
    aerosim::ImuSimulator imu_;
    bool imu_noise_enabled_ = false;
    bool imu_bias_enabled_ = false;
    bool imu_random_walk_enabled_ = false;
    bool imu_delay_enabled_ = false;
    bool flight_control_used_estimated_attitude_ = false;

public:
    std::int32_t probe_value() const;
    std::int32_t trajectory_stride() const;
    bool set_hardware_mass_kg(double mass_kg);
    void reset_simulation();
    godot::PackedFloat64Array step_simulation(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons);
    bool arm_flight_control(double throttle);
    bool flight_control_armed() const;
    godot::String flight_control_arm_reject_code() const;
    void reset_flight();
    void configure_imu(const godot::Dictionary &config);
    godot::Dictionary imu_configuration() const;
    godot::Dictionary flight_control_diagnostics() const;
    void set_collision_release_frames(std::int32_t release_frames);
    void sync_flight_state(
            double position_x,
            double position_y,
            double position_z,
            double orientation_x,
            double orientation_y,
            double orientation_z,
            double orientation_w,
            double velocity_x,
            double velocity_y,
            double velocity_z,
            double angular_velocity_x,
            double angular_velocity_y,
            double angular_velocity_z);
    godot::PackedFloat64Array step_angle_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double throttle,
            double roll_degrees,
            double pitch_degrees,
            double yaw_rate_degrees_per_second);
    godot::PackedFloat64Array step_collision_angle_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double throttle,
            double roll_degrees,
            double pitch_degrees,
            double yaw_rate_degrees_per_second,
            bool touching,
            double normal_x,
            double normal_y,
            double normal_z,
            double impulse_x,
            double impulse_y,
            double impulse_z,
            double restitution,
            double resolved_velocity_x,
            double resolved_velocity_y,
            double resolved_velocity_z,
            double resolved_angular_velocity_x,
            double resolved_angular_velocity_y,
            double resolved_angular_velocity_z,
            double max_kinetic_energy_joules);
    godot::PackedFloat64Array simulate_trajectory(
            double seconds,
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons) const;
};
