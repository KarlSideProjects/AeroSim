#!/usr/bin/env bash
set -euo pipefail

mkdir -p build
tmp_dir="$(mktemp -d build/delivery-drill-test.XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT
artifact="$tmp_dir/AeroSim-linux.zip"
report="$tmp_dir/report.json"
printf 'delivery-drill-test-artifact' >"$artifact"

scripts/exercise_delivery_drill.sh \
    --customer-id delivery-drill-test \
    --device-id local-test-rig \
    --artifact "$artifact" \
    --report "$report"

python3 - "$report" <<'PY'
import json
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["steps"] == [
    "customer_registered",
    "license_issued",
    "activation_verified",
    "license_revoked",
    "revocation_verified",
]
assert report["delivery_channel"] == "not_exercised"
assert "license_key" not in report
assert "token" not in report
PY
