#pragma once

#include <cstdint>
#include <memory>

#include "aerosim_collision.hpp"
#include "aerosim_flight_control.hpp"
#include "aerosim_imu.hpp"
#include "aerosim_replay.hpp"
#include "aerosim_simulation.hpp"
#include "aerosim_wind.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
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
    aerosim::Vec3 external_force_world_;
    aerosim::Vec3 downwash_source_position_world_;
    bool downwash_source_enabled_ = false;
    aerosim::CollisionAuthoritySwitch collision_authority_;
    aerosim::ImuConfig imu_config_;
    aerosim::ImuSimulator imu_;
    aerosim::ImuSample last_imu_sample_;
    bool has_last_imu_sample_ = false;
    aerosim::WindField wind_field_;
    std::unique_ptr<aerosim::ReplaySessionRecorder> replay_recorder_;
    godot::String wind_preset_name_ = "custom";
    bool imu_noise_enabled_ = false;
    bool imu_bias_enabled_ = false;
    bool imu_random_walk_enabled_ = false;
    bool imu_delay_enabled_ = false;
    bool flight_control_used_estimated_attitude_ = false;
    godot::String flight_mode_ = "ANGLE";
    aerosim::ImuSample sample_imu();
    void apply_downwash_provider(aerosim::SimulationConfig &config) const;

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
    bool set_body_drag_model(
            bool enabled,
            double coefficient_x,
            double coefficient_y,
            double coefficient_z,
            double frontal_area_x_m2,
            double frontal_area_y_m2,
            double frontal_area_z_m2,
            double center_of_pressure_x_m,
            double center_of_pressure_y_m,
            double center_of_pressure_z_m,
            double air_density_kg_m3);
    bool set_config_hash(const godot::String &config_hash);
    godot::String config_hash() const;
    godot::Dictionary body_drag_configuration() const;
    void reset_simulation();
    void set_external_force_world(double x, double y, double z);
    void set_a5_downwash_source_position(double x, double y, double z);
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
    godot::Dictionary replay_complete_session(
            const godot::String &serialized,
            const godot::String &expected_settings_manifest_hash,
            const godot::String &expected_upper_config_manifest_hash,
            const godot::String &expected_lower_config_manifest_hash,
            const godot::Dictionary &upper_config_manifest,
            const godot::Dictionary &lower_config_manifest);
    godot::Dictionary compare_complete_replay_sessions(
            const godot::String &expected_serialized,
            const godot::String &actual_serialized,
            const godot::String &expected_settings_manifest_hash);
    godot::Dictionary replay_vehicle_config_manifest() const;
    godot::String replay_manifest_hash(const godot::String &config_json) const;
    godot::Dictionary begin_complete_replay_recording(
            std::int64_t seed,
            const godot::String &settings_manifest_hash,
            const godot::String &upper_name,
            const godot::String &upper_config_manifest_hash,
            const godot::String &upper_config_json,
            std::int32_t upper_controller_authority,
            const godot::String &lower_name,
            const godot::String &lower_config_manifest_hash,
            const godot::String &lower_config_json,
            std::int32_t lower_controller_authority);
    godot::Dictionary record_replay_command(
            std::int64_t timestamp_us,
            const godot::String &vehicle_name,
            double throttle,
            double roll_degrees,
            double pitch_degrees,
            double yaw_rate_degrees_per_second,
            std::int32_t controller_authority);
    godot::Dictionary record_replay_mode_command(
            std::int64_t timestamp_us,
            const godot::String &vehicle_name,
            const godot::String &mode,
            double throttle,
            double roll,
            double pitch,
            double yaw,
            double rc_rate,
            double super_rate,
            double expo,
            double measured_altitude_m,
            std::int32_t controller_authority);
    godot::Dictionary record_replay_actuator_command(
            std::int64_t timestamp_us,
            const godot::String &vehicle_name,
            double motor_0,
            double motor_1,
            double motor_2,
            double motor_3,
            std::int32_t controller_authority);
    godot::Dictionary record_replay_simulation_operation(
            std::int64_t timestamp_us,
            std::int32_t operation,
            double value);
    godot::Dictionary record_replay_collision(
            std::int64_t timestamp_us,
            const godot::String &vehicle_name,
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
            double max_kinetic_energy_joules,
            bool has_resolved_state,
            std::int32_t controller_authority);
    godot::Dictionary record_replay_scene_object(
            std::int64_t timestamp_us,
            std::int32_t operation,
            const godot::String &object_name,
            const godot::String &asset_id,
            const godot::Vector3 &position,
            const godot::Quaternion &orientation);
    godot::Dictionary record_replay_environment(
            std::int64_t timestamp_us,
            const godot::String &environment_json);
    godot::Dictionary record_replay_checkpoint(
            std::int64_t timestamp_us,
            const godot::PackedFloat64Array &upper_row,
            const godot::PackedFloat64Array &lower_row,
            AeroSimNative *lower_native);
    godot::Dictionary record_replay_async_command(
            std::int64_t timestamp_us,
            const godot::String &vehicle_name,
            const godot::String &command_id,
            const godot::String &method,
            std::int32_t lifecycle);
    godot::Dictionary finish_complete_replay_recording(
            std::int64_t timestamp_us,
            const godot::String &reason);
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
    godot::Dictionary simulate_trajectory(
            double seconds,
            std::int32_t physics_hz,
            std::int32_t substep_hz,
            double total_thrust_newtons) const;
};
