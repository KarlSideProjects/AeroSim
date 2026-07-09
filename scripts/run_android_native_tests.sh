#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

artifact_path="/data/local/tmp/replay_terminal_state.json"
adb shell mkdir -p /data/local/tmp/aerosim-tests

ran_tests=0
for test_binary in build/tests/test_*; do
    case "$test_binary" in
        *.exe) continue ;;
    esac
    adb push "$test_binary" /data/local/tmp/aerosim-tests/ >/dev/null
    adb shell chmod 755 "/data/local/tmp/aerosim-tests/$(basename "$test_binary")"
    adb shell "AEROSIM_REPLAY_ARTIFACT=$artifact_path /data/local/tmp/aerosim-tests/$(basename "$test_binary")"
    ran_tests=1
done

if [ "$ran_tests" -eq 0 ]; then
    echo "no Android native test binaries found under build/tests" >&2
    exit 1
fi

mkdir -p build
adb pull "$artifact_path" build/replay_terminal_state.json
