#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tests
for test_source in tests/native/test_*.cpp; do
    test_name=$(basename "${test_source}" .cpp)
    ${CXX:-g++} -std=c++17 -Wall -Wextra -Werror -Isrc/native \
        "${test_source}" src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp \
        -o "build/tests/${test_name}"
    "build/tests/${test_name}"
done
