#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tests
run_tests="${AEROSIM_RUN_NATIVE_TESTS:-1}"
exe_suffix="${EXE_SUFFIX:-}"
native_sources=(
    src/native/aerosim_simulation.cpp
    src/native/aerosim_flight_control.cpp
    src/native/aerosim_replay.cpp
)
for test_source in tests/native/test_*.cpp; do
    test_name=$(basename "${test_source}" .cpp)
    output="build/tests/${test_name}${exe_suffix}"
    ${CXX:-g++} ${CXXFLAGS:-} -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native \
        "${test_source}" "${native_sources[@]}" \
        -o "$output"
    if [ "$run_tests" != "0" ]; then
        "$output"
    fi
done
