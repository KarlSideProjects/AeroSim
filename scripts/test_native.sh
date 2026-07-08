#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/tests
${CXX:-g++} -std=c++17 -Wall -Wextra -Werror -Isrc/native \
    tests/native/test_probe.cpp -o build/tests/test_probe
build/tests/test_probe
