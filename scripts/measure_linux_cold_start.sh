#!/usr/bin/env bash
set -euo pipefail

release_bin="${AEROSIM_LINUX_RELEASE_BIN:-build/release/AeroSim-linux/AeroSim.x86_64}"
report_path="${AEROSIM_COLD_START_REPORT:-build/cold_start/linux.json}"
max_seconds="${AEROSIM_COLD_START_MAX_SECONDS:-15}"
visible_seconds="${AEROSIM_COLD_START_VISIBLE_SECONDS:-3}"

if [ -z "${DISPLAY:-}" ]; then
    echo "missing DISPLAY; Linux cold-start evidence must use a real local display" >&2
    exit 1
fi
if [ ! -x "$release_bin" ]; then
    echo "missing Linux release executable: $release_bin" >&2
    echo "run scripts/export_linux_release.sh first" >&2
    exit 1
fi
if pgrep -x Xvfb >/dev/null 2>&1; then
    echo "Xvfb is active; Linux cold-start acceptance requires a real local display" >&2
    exit 1
fi
if ! [[ "$max_seconds" =~ ^[0-9]+$ ]] || [ "$max_seconds" -le 0 ]; then
    echo "AEROSIM_COLD_START_MAX_SECONDS must be a positive whole number" >&2
    exit 1
fi
if ! [[ "$visible_seconds" =~ ^[0-9]+$ ]] || [ "$visible_seconds" -le 0 ]; then
    echo "AEROSIM_COLD_START_VISIBLE_SECONDS must be a positive whole number" >&2
    exit 1
fi

mkdir -p "$(dirname "$report_path")"
report_path="$(realpath -m "$report_path")"
screenshot_path="${report_path%.json}.png"
rm -f "$report_path"
rm -f "$screenshot_path"
started_ns="$(date +%s%N)"
"$release_bin" -- \
    --aerosim-cold-start-report "$report_path" \
    --aerosim-cold-start-screenshot "$screenshot_path" \
    --aerosim-cold-start-visible-seconds "$visible_seconds" &
release_pid="$!"
deadline=$((SECONDS + max_seconds + visible_seconds + 5))
report_seen_ns=""

while kill -0 "$release_pid" 2>/dev/null; do
    if [ -s "$report_path" ] && python3 -m json.tool "$report_path" >/dev/null 2>&1; then
        report_seen_ns="$(date +%s%N)"
        break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        kill "$release_pid" 2>/dev/null || true
        wait "$release_pid" 2>/dev/null || true
        echo "Linux cold-start probe timed out before writing a report" >&2
        exit 124
    fi
    sleep 0.05
done
if [ -z "$report_seen_ns" ]; then
    echo "Linux cold-start probe exited before writing a valid report" >&2
    wait "$release_pid" || true
    exit 1
fi
wait "$release_pid"

python3 - "$report_path" "$screenshot_path" "$started_ns" "$report_seen_ns" "$max_seconds" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
screenshot_path = Path(sys.argv[2])
started_ns, report_seen_ns, max_seconds = map(int, sys.argv[3:])
if not path.is_file():
    raise SystemExit(f"cold-start probe did not write {path}")

result = json.loads(path.read_text(encoding="utf-8"))
elapsed_ms = (report_seen_ns - started_ns) / 1_000_000
result["elapsed_ms"] = elapsed_ms
result["threshold_seconds"] = max_seconds
path.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")

if not result.get("flyable"):
    raise SystemExit(f"cold-start probe did not reach a flyable screen: {result.get('screen')}")
if result.get("display_driver") == "headless":
    raise SystemExit("cold-start probe used Godot headless display driver")
if not result.get("frame_post_draw") or not result.get("screenshot_written") or not screenshot_path.is_file():
    raise SystemExit("cold-start probe did not produce a rendered screenshot")
if elapsed_ms > max_seconds * 1000:
    raise SystemExit(f"cold-start exceeded {max_seconds}s: {elapsed_ms:.3f}ms")
print(f"Linux cold start: {elapsed_ms:.3f}ms (<= {max_seconds}s)")
PY
