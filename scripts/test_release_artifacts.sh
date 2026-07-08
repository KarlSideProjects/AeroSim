#!/usr/bin/env bash
set -euo pipefail

test -s docs/release_delivery_sop.md

artifact="$(mktemp build/release-artifact.XXXXXX)"
out_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$artifact" "$out_file" "$err_file"' EXIT

printf 'artifact' >"$artifact"
python3 scripts/check_release_artifacts.py "$artifact" >"$out_file"
grep -q "$artifact: 8 bytes" "$out_file"

if python3 scripts/check_release_artifacts.py build/does-not-exist.zip >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing release artifact unexpectedly passed" >&2
    exit 1
fi

grep -q "missing artifact: build/does-not-exist.zip" "$err_file"
