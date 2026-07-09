#!/usr/bin/env bash
set -euo pipefail

test -s docs/release_delivery_sop.md
grep -q "scripts/export_android_release.sh" docs/release_delivery_sop.md
test -x scripts/export_android_release.sh

mkdir -p build
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

if GODOT_EXPORT_TEMPLATES_DIR=build/does-not-exist \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing Android export template unexpectedly passed" >&2
    exit 1
fi

grep -q "missing Godot Android export template: build/does-not-exist/android_release.apk" "$err_file"
