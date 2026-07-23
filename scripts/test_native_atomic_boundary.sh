#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
extension="bin/libaerosim_native.linux.template_debug.x86_64.so"
if [[ "$godot_bin" == */* ]]; then
    godot_available="$(test -x "$godot_bin" && echo true || echo false)"
else
    godot_available="$(command -v "$godot_bin" >/dev/null && echo true || echo false)"
fi
if [ "$godot_available" != true ] || [ ! -f "$extension" ]; then
    echo "GODOT_BIN and $extension are required" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/validate_native_provenance.sh"
validate_native_provenance

mkdir -p build/native_atomic_boundary
for scenario in sparse_px4 negative legacy_atomic collision_px4_rollback huge_angle trajectory_contract hardware_mass imu_rollback; do
    log="build/native_atomic_boundary/${scenario}.log"
    rm -f "$log"
    "$godot_bin" --headless --path . --log-file "$log" \
        --script res://tests/headless/native_atomic_boundary_harness.gd -- --scenario "$scenario"
done

negative_log="build/native_atomic_boundary/negative.log"
expected='ERROR: AeroSimNative.step_angle_mode: InvalidCommand: command/config/state'
if [ "$(grep -Fxc "$expected" "$negative_log" || true)" -ne 1 ] || [ "$(grep -Ec '^ERROR:' "$negative_log" || true)" -ne 1 ]; then
    echo "negative public-step acceptance did not produce exactly one expected native ERROR line" >&2
    exit 1
fi

legacy_log="build/native_atomic_boundary/legacy_atomic.log"
single_error='ERROR: AeroSimNative.step_simulation: InvalidCommand: thrust'
dual_error='ERROR: AeroSimNative.step_dual_aircraft_simulation: InvalidCommand: thrust'
if [ "$(grep -Fxc "$single_error" "$legacy_log" || true)" -ne 3 ] || [ "$(grep -Fxc "$dual_error" "$legacy_log" || true)" -ne 3 ] || [ "$(grep -Ec '^ERROR:' "$legacy_log" || true)" -ne 6 ]; then
    echo "legacy public-step acceptance did not produce exactly one native ERROR per rejected thrust" >&2
    exit 1
fi

echo "native atomic boundary: sparse PX4, legacy rollback, runtime hardware mass, public IMU rollback, and one-error acceptance passed"
