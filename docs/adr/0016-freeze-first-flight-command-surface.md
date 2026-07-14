# Freeze the first flight command surface

The first AirSim Compatibility Surface will support takeoff, land, hover, return home, position, path, velocity, yaw, and attitude or body-rate plus throttle commands for both named vehicles and both supported flight-controller types. AirSim asynchronous completion and cancellation behavior is part of the contract; direct per-motor PWM is explicitly unsupported because it bypasses the flight-controller boundary required by the minimum.
