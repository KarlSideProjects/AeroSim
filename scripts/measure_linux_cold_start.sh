#!/usr/bin/env bash
set -euo pipefail

release_bin="${AEROSIM_LINUX_RELEASE_BIN:-build/release/AeroSim-linux/AeroSim.x86_64}"
report_path="${AEROSIM_COLD_START_REPORT:-build/cold_start/linux.json}"
max_seconds="${AEROSIM_COLD_START_MAX_SECONDS:-15}"

if [ -z "${DISPLAY:-}" ]; then
    echo "missing DISPLAY; Linux cold-start evidence must use a real local display" >&2
    exit 1
fi
if [ ! -x "$release_bin" ]; then
    echo "missing Linux release executable: $release_bin" >&2
    echo "run scripts/export_linux_release.sh first" >&2
    exit 1
fi
if ! [[ "$max_seconds" =~ ^[0-9]+$ ]] || [ "$max_seconds" -le 0 ]; then
    echo "AEROSIM_COLD_START_MAX_SECONDS must be a positive whole number" >&2
    exit 1
fi

mkdir -p "$(dirname "$report_path")"
report_path="$(realpath -m "$report_path")"
rm -f "$report_path"
started_ns="$(date +%s%N)"
"$release_bin" -- --aerosim-cold-start-report "$report_path" &
release_pid="$!"
deadline=$((SECONDS + max_seconds + 5))

while kill -0 "$release_pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        kill "$release_pid" 2>/dev/null || true
        wait "$release_pid" 2>/dev/null || true
        echo "Linux cold-start probe timed out before writing a report" >&2
        exit 124
    fi
    sleep 0.05
done
wait "$release_pid"
finished_ns="$(date +%s%N)"

python3 - "$report_path" "$started_ns" "$finished_ns" "$max_seconds" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
started_ns, finished_ns, max_seconds = map(int, sys.argv[2:])
if not path.is_file():
    raise SystemExit(f"cold-start probe did not write {path}")

result = json.loads(path.read_text(encoding="utf-8"))
elapsed_ms = (finished_ns - started_ns) / 1_000_000
result["elapsed_ms"] = elapsed_ms
result["threshold_seconds"] = max_seconds
path.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")

if not result.get("flyable"):
    raise SystemExit(f"cold-start probe did not reach a flyable screen: {result.get('screen')}")
if elapsed_ms > max_seconds * 1000:
    raise SystemExit(f"cold-start exceeded {max_seconds}s: {elapsed_ms:.3f}ms")
print(f"Linux cold start: {elapsed_ms:.3f}ms (<= {max_seconds}s)")
PY
