#!/usr/bin/env bash
set -euo pipefail

if [ "${AEROSIM_GSP_IDLE_WARMUP_SECONDS:-10}" -ne 10 ] || [ "${AEROSIM_GSP_IDLE_SECONDS:-60}" -ne 60 ]; then
    echo "GSP idle qualification is frozen at 10s warmup and 60s measurement" >&2
    exit 2
fi

exec python3 "$(dirname "$0")/run_gsp_idle_benchmark.py"
