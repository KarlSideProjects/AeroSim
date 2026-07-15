#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tests
run_tests="${AEROSIM_RUN_NATIVE_TESTS:-1}"
exe_suffix="${EXE_SUFFIX:-}"
native_sources=(
    src/native/aerosim_aerodynamics.cpp
    src/native/aerosim_simulation.cpp
    src/native/aerosim_flight_control.cpp
    src/native/aerosim_imu.cpp
    src/native/aerosim_wind.cpp
    src/native/aerosim_collision.cpp
    src/native/aerosim_replay.cpp
)
for test_source in tests/native/test_*.cpp; do
    test_name=$(basename "${test_source}" .cpp)
    output="build/tests/${test_name}${exe_suffix}"
    if [ "${AEROSIM_MSVC:-0}" = "1" ]; then
        ${CXX:-cl} /nologo /std:c++17 /W4 /WX /EHsc /fp:strict /D_CRT_SECURE_NO_WARNINGS /Isrc/native \
            "${test_source}" "${native_sources[@]}" \
            /Fe:"$output"
    else
        ${CXX:-g++} ${CXXFLAGS:-} -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native \
            "${test_source}" "${native_sources[@]}" \
            -o "$output"
    fi
    if [ "$run_tests" != "0" ]; then
        "$output"
    fi
done
