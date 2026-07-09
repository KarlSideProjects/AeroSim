#include "aerosim_flight_control.hpp"

#include <cmath>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

std::vector<std::string> split_csv_line(const std::string &line) {
    std::vector<std::string> cells;
    std::stringstream stream(line);
    std::string cell;
    while (std::getline(stream, cell, ',')) {
        cells.push_back(cell);
    }
    return cells;
}

double degrees(double radians) {
    return radians * 180.0 / kPi;
}

double roll_degrees(const aerosim::Quat &q) {
    return degrees(2.0 * std::atan2(q.z, q.w));
}

double pitch_degrees(const aerosim::Quat &q) {
    return degrees(2.0 * std::atan2(q.x, q.w));
}

double yaw_degrees(const aerosim::Quat &q) {
    return degrees(2.0 * std::atan2(q.y, q.w));
}

aerosim::SimulationConfig validation_config() {
    aerosim::SimulationConfig config;
    config.seconds = 1.0;
    config.physics_hz = 240;
    config.substep_hz = 1000;
    config.hover_throttle = 0.5;
    config.max_total_thrust_newtons = config.mass_kg * config.gravity_mps2 * 2.0;
    config.battery_nominal_voltage_v = 22.2;
    config.battery_cells = 6.0;
    config.battery_cell_resistance_ohm = 0.0;
    config.max_total_current_a = 1.0;
    return config;
}

} // namespace

int main() {
    std::string header;
    if (!std::getline(std::cin, header)) {
        std::cerr << "missing input CSV header\n";
        return 1;
    }
    if (header != "time_s,throttle,roll_degrees,pitch_degrees,yaw_rate_degrees_per_second") {
        std::cerr << "unexpected input CSV header: " << header << "\n";
        return 1;
    }

    aerosim::RigidBodyState state;
    aerosim::SimulationClock clock;
    aerosim::FlightController controller;
    if (!controller.arm(0.0)) {
        std::cerr << "reference controller failed to arm\n";
        return 1;
    }

    const aerosim::SimulationConfig config = validation_config();
    std::cout << "time_s,roll_degrees,pitch_degrees,yaw_degrees\n";
    std::cout << std::fixed << std::setprecision(9);

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) {
            continue;
        }
        const std::vector<std::string> cells = split_csv_line(line);
        if (cells.size() != 5) {
            std::cerr << "invalid input CSV row: " << line << "\n";
            return 1;
        }

        aerosim::FlightCommand command;
        command.throttle = std::stod(cells[1]);
        command.roll_degrees = std::stod(cells[2]);
        command.pitch_degrees = std::stod(cells[3]);
        command.yaw_rate_degrees_per_second = std::stod(cells[4]);

        const aerosim::TrajectorySample sample =
                controller.step_angle_mode(state, clock, config, command);
        std::cout << sample.time_seconds << ','
                  << roll_degrees(sample.state.orientation) << ','
                  << pitch_degrees(sample.state.orientation) << ','
                  << yaw_degrees(sample.state.orientation) << '\n';
    }

    return 0;
}
