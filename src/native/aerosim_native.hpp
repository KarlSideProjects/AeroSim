#pragma once

#include <cstdint>

#include "aerosim_collision.hpp"
#include "aerosim_flight_control.hpp"
#include "aerosim_imu.hpp"
#include "aerosim_simulation.hpp"
#include "aerosim_wind.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

class AeroSimNative : public godot::RefCounted {
    GDCLASS(AeroSimNative, godot::RefCounted)

protected:
    static void _bind_methods();

private:
    aerosim::RigidBodyState simulation_state_;
    aerosim::SimulationClock simulation_clock_;
    aerosim::DualAircraftState dual_aircraft_state_;
    aerosim::SimulationClock dual_aircraft_clock_;
    aerosim::HardwareConfig hardware_config_;
    aerosim::FlightController flight_controller_;
    aerosim::A4GroundEffectConfig a4_ground_effect_config_;
    aerosim::A5DownwashConfig a5_downwash_config_;
    aerosim::CollisionAuthoritySwitch collision_authority_;
    aerosim::ImuConfig imu_config_;
    aerosim::ImuSimulator imu_;
    aerosim::ImuSample last_imu_sample_;
    bool has_last_imu_sample_ = false;
    aerosim::WindField wind_field_;
    godot::String wind_preset_name_ = "custom";
    bool imu_noise_enabled_ = false;
    bool imu_bias_enabled_ = false;
    bool imu_random_walk_enabled_ = false;
    bool imu_delay_enabled_ = false;
    bool flight_control_used_estimated_attitude_ = false;
    godot::String flight_mode_ = "ANGLE";
    aerosim::ImuSample sample_imu();

public:
    std::int32_t probe_value() const;
    std::int32_t trajectory_stride() const;
    bool set_hardware_mass_kg(double mass_kg);
    bool set_hardware_power_model(
            double max_total_thrust_newtons,
            double hover_throttle,
            double motor_tau_s,
            double battery_nominal_voltage_v,
            double battery_cells,
            double battery_cell_resistance_ohm,
            double max_total_current_a);
    bool set_hardware_telemetry_model(double max_motor_rpm, double battery_remaining_mah);
    bool set_hardware_per_motor_model(const godot::Dictionary &model);
    void reset_simulation();
    bool set_dual_aircraft_positions(
            double upper_x,
            double upper_y,
            double upper_z,
            double lower_x,
            double lower_y,
            double lower_z);
    godot::PackedFloat64Array step_dual_aircraft_simulation(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons);
    godot::PackedFloat64Array step_simulation(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons);
    // PX4 actuator modes, including the collision variant, receive arming authority from the PX4 bridge, not the local flight controller.
    godot::PackedFloat64Array step_px4_actuator_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double motor_0,
            double motor_1,
            double motor_2,
            double motor_3);
    godot::PackedFloat64Array step_collision_px4_actuator_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double motor_0,
            double motor_1,
            double motor_2,
            double motor_3,
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
    bool arm_flight_control(double throttle);
    void disarm_flight_control();
    bool flight_control_armed() const;
    godot::String flight_control_arm_reject_code() const;
    double betaflight_stick_for_rate(
            double rate_degrees_per_second,
            double rc_rate,
            double super_rate,
            double expo) const;
    double betaflight_rate_for_stick(
            double stick,
            double rc_rate,
            double super_rate,
            double expo) const;
    void reset_flight();
    void capture_altitude_hold();
    void configure_imu(const godot::Dictionary &config);
    godot::Dictionary imu_configuration() const;
    godot::Dictionary imu_sample() const;
    void refresh_imu_sample();
    void configure_wind(const godot::Dictionary &config);
    godot::Dictionary wind_configuration() const;
    godot::Vector3 sample_wind(double time_seconds, double position_x, double position_y, double position_z) const;
    godot::Dictionary flight_control_diagnostics() const;
    godot::Dictionary hardware_power_diagnostics() const;
    godot::Dictionary hardware_per_motor_diagnostics() const;
    godot::Dictionary telemetry_snapshot() const;
    bool set_a3_drag_model(bool enabled, double coefficient_x_kg, double coefficient_y_kg, double coefficient_z_kg);
    godot::Dictionary a3_drag_configuration() const;
    bool set_a6_propwash_model(
            bool enabled,
            double full_collective_angular_accel_rad_s2,
            double minimum_wake_entry_speed_mps,
            double minimum_transverse_rate_rad_s);
    godot::Dictionary a6_propwash_configuration() const;
    bool set_a4_ground_effect_model(
            bool enabled,
            double kf,
            double ground_effect_coeff,
            double prop_radius_m,
            double height_clip_m,
            double motor_0_rpm,
            double motor_1_rpm,
            double motor_2_rpm,
            double motor_3_rpm);
    godot::Dictionary a4_ground_effect_configuration() const;
    bool set_a5_downwash_model(
            bool enabled,
            double prop_radius_m,
            double coeff_1,
            double coeff_2,
            double coeff_3);
    godot::Dictionary a5_downwash_configuration() const;
    double a5_downwash_force_y(
            double upper_x,
            double upper_y,
            double upper_z,
            double lower_x,
            double lower_y,
            double lower_z) const;
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
    godot::PackedFloat64Array step_acro_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double throttle,
            double roll_stick,
            double pitch_stick,
            double yaw_stick,
            double rc_rate,
            double super_rate,
            double expo);
    godot::PackedFloat64Array step_altitude_hold_mode(
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
    godot::PackedFloat64Array step_collision_altitude_hold_mode(
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
    godot::PackedFloat64Array step_collision_acro_mode(
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double throttle,
            double roll_stick,
            double pitch_stick,
            double yaw_stick,
            double rc_rate,
            double super_rate,
            double expo,
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
