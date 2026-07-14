#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PX4_REPOSITORY="https://github.com/PX4/PX4-Autopilot.git"
PX4_REVISION="1dacb4cdef2d7145754fc788fa8dc482eed74b40"
PX4_SOURCE_DIR="${PX4_SOURCE_DIR:-$ROOT_DIR/build/px4}"
mode="check"
fake_smoke=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            mode="check"
            shift
            ;;
        --run)
            mode="run"
            shift
            ;;
        --fake-smoke)
            fake_smoke=true
            shift
            ;;
        *)
            echo "usage: $0 [--check|--run] [--fake-smoke]" >&2
            exit 2
            ;;
    esac
done

if ! command -v git >/dev/null 2>&1; then
    echo '{"ok":false,"error":"git is required"}' >&2
    exit 1
fi

if [ "$mode" = "check" ]; then
    if [ -e "$PX4_SOURCE_DIR" ]; then
        actual_revision="$(git -C "$PX4_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
        if [ "$actual_revision" != "$PX4_REVISION" ]; then
            echo "PX4 source exists at $PX4_SOURCE_DIR but is not pinned to $PX4_REVISION (actual: ${actual_revision:-unavailable})" >&2
            exit 1
        fi
    fi
    printf '{"ok":true,"mode":"check","repository":"%s","revision":"%s","source_dir":"%s"}\n' "$PX4_REPOSITORY" "$PX4_REVISION" "$PX4_SOURCE_DIR"
    if [ "$fake_smoke" = true ]; then
        godot_bin="${GODOT_BIN:-godot}"
        if [[ "$godot_bin" == */* ]]; then
            [ -x "$godot_bin" ] || { echo "Godot executable is missing: $godot_bin" >&2; exit 1; }
        elif ! command -v "$godot_bin" >/dev/null 2>&1; then
            echo "Godot executable was not found: $godot_bin" >&2
            exit 1
        fi
        mkdir -p "$ROOT_DIR/build"
        "$godot_bin" --headless --path "$ROOT_DIR" --script res://tests/headless/px4_sitl_smoke.gd -- --output build/px4_sitl_smoke.json
        python3 - <<'PY'
import json
with open("build/px4_sitl_smoke.json", encoding="utf-8") as handle:
    report = json.load(handle)
if report.get("completed") is not True or report.get("mission_phase") != "disarmed":
    raise SystemExit("PX4 fake mission did not finish disarmed")
print("PX4 fake mission: completed and disarmed")
PY
    fi
    exit 0
fi

if [ -z "${GODOT_BIN:-}" ]; then
    echo "--run requires GODOT_BIN set to the pinned Godot executable" >&2
    exit 1
fi
if [[ "$GODOT_BIN" == */* ]]; then
    [ -x "$GODOT_BIN" ] || { echo "Godot executable is missing: $GODOT_BIN" >&2; exit 1; }
elif ! command -v "$GODOT_BIN" >/dev/null 2>&1; then
    echo "Godot executable was not found: $GODOT_BIN" >&2
    exit 1
fi
if [ ! -d "$PX4_SOURCE_DIR/.git" ]; then
    mkdir -p "$(dirname "$PX4_SOURCE_DIR")"
    git clone --filter=blob:none "$PX4_REPOSITORY" "$PX4_SOURCE_DIR"
fi
git -C "$PX4_SOURCE_DIR" fetch --tags --quiet origin "$PX4_REVISION"
git -C "$PX4_SOURCE_DIR" checkout --detach --quiet "$PX4_REVISION"
if [ "$(git -C "$PX4_SOURCE_DIR" rev-parse HEAD)" != "$PX4_REVISION" ]; then
    echo "PX4 checkout is not pinned to $PX4_REVISION" >&2
    exit 1
fi

log_dir="$ROOT_DIR/build/px4_sitl"
mkdir -p "$log_dir"
px4_log="$log_dir/px4.log"
mission_log="$log_dir/mission.log"
tmp_dir="$(mktemp -d)"
ready_file="$tmp_dir/ready"
stop_file="$tmp_dir/stop"
godot_log="$tmp_dir/godot.log"
venv_dir="$tmp_dir/venv"
GODOT_PID=""
cleanup() {
    if [ -n "${PX4_PID:-}" ] && kill -0 "$PX4_PID" 2>/dev/null; then
        kill "$PX4_PID" 2>/dev/null || true
        wait "$PX4_PID" 2>/dev/null || true
    fi
    touch "$stop_file"
    if [ -n "$GODOT_PID" ] && kill -0 "$GODOT_PID" 2>/dev/null; then
        wait "$GODOT_PID" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

make -C "$PX4_SOURCE_DIR" px4_sitl none_iris >"$px4_log" 2>&1 &
PX4_PID=$!
sleep "${AEROSIM_PX4_STARTUP_SECONDS:-10}"
if ! kill -0 "$PX4_PID" 2>/dev/null; then
    cat "$px4_log" >&2
    echo "PX4 SITL exited before the mission command started" >&2
    exit 1
fi

"$GODOT_BIN" --headless --path "$ROOT_DIR" \
    -- --airsim-settings-file "$ROOT_DIR/config/sitl/px4_iris.json" \
    --airsim-ready-file "$ready_file" --airsim-stop-file "$stop_file" \
    >"$godot_log" 2>&1 &
GODOT_PID=$!
for _attempt in $(seq 1 90); do
    if [ -f "$ready_file" ]; then
        break
    fi
    if ! kill -0 "$GODOT_PID" 2>/dev/null; then
        cat "$godot_log" >&2
        echo "Godot exited before the PX4 RPC bridge became ready" >&2
        exit 1
    fi
    sleep 1
done
if [ ! -f "$ready_file" ]; then
    cat "$godot_log" >&2
    echo "PX4 RPC bridge did not become ready" >&2
    exit 1
fi

python3 -m venv "$venv_dir"
"$venv_dir/bin/python" -m pip install --disable-pip-version-check --quiet \
    setuptools wheel numpy opencv-contrib-python msgpack-rpc-python backports.ssl_match_hostname airsim==1.8.1
if ! "$venv_dir/bin/python" "$ROOT_DIR/scripts/px4_sitl_mission.py" --port 41451 >"$mission_log" 2>&1; then
    cat "$mission_log" >&2
    exit 1
fi
printf '{"ok":true,"mode":"run","revision":"%s","px4_log":"%s","mission_log":"%s"}\n' "$PX4_REVISION" "$px4_log" "$mission_log"
