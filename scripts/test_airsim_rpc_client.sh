#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:?set GODOT_BIN to the pinned Godot executable}"
PYTHON_BIN="${PYTHON_BIN:-}"
PORT="${AEROSIM_RPC_TEST_PORT:-41459}"
TMP_DIR="$(mktemp -d)"
READY_FILE="$TMP_DIR/ready"
STOP_FILE="$TMP_DIR/stop"
VENV_DIR="$TMP_DIR/venv"
GODOT_PID=""

cleanup() {
    touch "$STOP_FILE"
    if [[ -n "$GODOT_PID" ]] && kill -0 "$GODOT_PID" 2>/dev/null; then
        wait "$GODOT_PID" || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ -z "$PYTHON_BIN" ]]; then
    if command -v python3.12 >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3.12)"
    else
        PYTHON_BIN="$(command -v python3)"
    fi
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --quiet \
    setuptools wheel numpy opencv-contrib-python msgpack-rpc-python backports.ssl_match_hostname
"$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --quiet airsim==1.8.1

"$GODOT_BIN" --headless --path "$ROOT_DIR" \
    --script res://tests/headless/airsim_rpc_harness.gd -- \
    --rpc-port "$PORT" --ready-file "$READY_FILE" --stop-file "$STOP_FILE" \
    >"$TMP_DIR/godot.log" 2>&1 &
GODOT_PID=$!

for _attempt in $(seq 1 60); do
    if [[ -f "$READY_FILE" ]]; then
        break
    fi
    if ! kill -0 "$GODOT_PID" 2>/dev/null; then
        cat "$TMP_DIR/godot.log"
        exit 1
    fi
    sleep 1
done

if [[ ! -f "$READY_FILE" ]]; then
    cat "$TMP_DIR/godot.log"
    exit 1
fi

"$VENV_DIR/bin/python" "$ROOT_DIR/scripts/airsim_rpc_client_smoke.py" --port "$PORT"
