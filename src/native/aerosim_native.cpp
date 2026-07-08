#include "aerosim_native.hpp"

#include "aerosim_probe.hpp"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void AeroSimNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("probe_value"), &AeroSimNative::probe_value);
    ClassDB::bind_method(D_METHOD("trajectory_stride"), &AeroSimNative::trajectory_stride);
    ClassDB::bind_method(D_METHOD("reset_simulation"), &AeroSimNative::reset_simulation);
    ClassDB::bind_method(
            D_METHOD("step_simulation", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::step_simulation);
    ClassDB::bind_method(
            D_METHOD("simulate_trajectory", "seconds", "physics_hz", "substep_hz", "total_thrust_newtons"),
            &AeroSimNative::simulate_trajectory);
}

std::int32_t AeroSimNative::probe_value() const {
    return aerosim::probe_value();
}

std::int32_t AeroSimNative::trajectory_stride() const {
    return 12;
}

void AeroSimNative::reset_simulation() {
    simulation_state_ = {};
    simulation_clock_ = {};
}

PackedFloat64Array AeroSimNative::step_simulation(
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double total_thrust_newtons) {
    aerosim::SimulationConfig config;
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.total_thrust_newtons = total_thrust_newtons;

    PackedFloat64Array row;
    const aerosim::TrajectorySample sample = aerosim::step_physics_frame(simulation_state_, simulation_clock_, config);
    row.append(sample.time_seconds);
    row.append(sample.state.position.x);
    row.append(sample.state.position.y);
    row.append(sample.state.position.z);
    row.append(sample.state.orientation.x);
    row.append(sample.state.orientation.y);
    row.append(sample.state.orientation.z);
    row.append(sample.state.orientation.w);
    row.append(sample.state.velocity.x);
    row.append(sample.state.velocity.y);
    row.append(sample.state.velocity.z);
    row.append(static_cast<double>(sample.substeps));
    return row;
}

PackedFloat64Array AeroSimNative::simulate_trajectory(
        double seconds,
        std::int32_t physics_hz,
        std::int32_t substep_hz,
        double total_thrust_newtons) const {
    aerosim::SimulationConfig config;
    config.seconds = seconds;
    config.physics_hz = physics_hz;
    config.substep_hz = substep_hz;
    config.total_thrust_newtons = total_thrust_newtons;

    PackedFloat64Array rows;
    for (const aerosim::TrajectorySample &sample : aerosim::simulate_trajectory(config)) {
        rows.append(sample.time_seconds);
        rows.append(sample.state.position.x);
        rows.append(sample.state.position.y);
        rows.append(sample.state.position.z);
        rows.append(sample.state.orientation.x);
        rows.append(sample.state.orientation.y);
        rows.append(sample.state.orientation.z);
        rows.append(sample.state.orientation.w);
        rows.append(sample.state.velocity.x);
        rows.append(sample.state.velocity.y);
        rows.append(sample.state.velocity.z);
        rows.append(static_cast<double>(sample.substeps));
    }
    return rows;
}
