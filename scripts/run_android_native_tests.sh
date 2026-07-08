#!/usr/bin/env bash
set -euo pipefail

artifact_path="/data/local/tmp/replay_terminal_state.json"
adb shell mkdir -p /data/local/tmp/aerosim-tests

for test_binary in build/tests/test_*; do
    adb push "$test_binary" /data/local/tmp/aerosim-tests/ >/dev/null
    adb shell chmod 755 "/data/local/tmp/aerosim-tests/$(basename "$test_binary")"
    adb shell "AEROSIM_REPLAY_ARTIFACT=$artifact_path /data/local/tmp/aerosim-tests/$(basename "$test_binary")"
done

mkdir -p build
adb pull "$artifact_path" build/replay_terminal_state.json
