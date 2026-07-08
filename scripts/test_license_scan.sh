#!/usr/bin/env bash
set -euo pipefail

python3 scripts/check_licenses.py

out_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$out_file" "$err_file"' EXIT

if python3 scripts/check_licenses.py --manifest tests/fixtures/gpl_dependency.json >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "GPL fixture unexpectedly passed" >&2
    exit 1
fi

grep -q "license denied: bad-flight-controller 0.0.0 (GPL-3.0)" "$err_file"
echo "GPL fixture failed as expected"
