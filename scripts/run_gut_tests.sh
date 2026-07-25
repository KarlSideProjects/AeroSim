#!/usr/bin/env bash
set -euo pipefail

case "$#" in
    0)
        recovery_mode=false
        ;;
    1)
        if [ "$1" != "--recovery-mode" ]; then
            echo "usage: $0 [--recovery-mode]" >&2
            exit 2
        fi
        recovery_mode=true
        ;;
    *)
        echo "usage: $0 [--recovery-mode]" >&2
        exit 2
        ;;
esac

godot_bin="${GODOT_BIN:-godot}"
if [[ "$godot_bin" == */* ]]; then
    if [ ! -x "$godot_bin" ]; then
        echo "Godot executable is missing or not executable: $godot_bin" >&2
        exit 1
    fi
elif ! command -v "$godot_bin" >/dev/null; then
    echo "Godot executable was not found on PATH: $godot_bin" >&2
    exit 1
fi

if [ "$recovery_mode" = false ]; then
    native_extension="bin/libaerosim_native.linux.template_debug.x86_64.so"
    if [ ! -f "$native_extension" ]; then
        echo "required Linux debug GDExtension is missing: $native_extension" >&2
        exit 1
    fi
    source "$(dirname "${BASH_SOURCE[0]}")/validate_native_provenance.sh"
    validate_native_provenance
fi

out_dir="build/gut"
import_log="$out_dir/import.log"
godot_log="$out_dir/godot.log"
junit="$out_dir/junit.xml"
mkdir -p "$out_dir"
mkdir -p .godot
if [ "$recovery_mode" = true ]; then
    project_config_backup="$(mktemp)"
    cp project.godot "$project_config_backup"
    trap 'cp "$project_config_backup" project.godot; rm -f "$project_config_backup"' EXIT
    sed -i 's|enabled=PackedStringArray("res://addons/terrain_3d/plugin.cfg")|enabled=PackedStringArray()|' project.godot
else
    printf '%s\n' \
        'res://extensions/aerosim_native/aerosim_native.gdextension' \
        'res://addons/terrain_3d/terrain.gdextension' > .godot/extension_list.cfg
fi
touch build/.gdignore
rm -f "$import_log" "$godot_log" "$junit"

import_args=()
if [ "$recovery_mode" = true ]; then
    import_args=(--editor --recovery-mode)
fi

"$godot_bin" --headless --path . --log-file "$import_log" "${import_args[@]}" --import || {
    status=$?
    echo "Godot import failed with status $status" >&2
    exit "$status"
}

if [ "$recovery_mode" = true ]; then
    # Recovery import builds GUT's global class cache without loading GDExtensions.
    # Keep the following CLI test run isolated from the generated extension cache.
    rm -f .godot/extension_list.cfg
fi

"$godot_bin" --headless --path . --log-file "$godot_log" \
    --script res://addons/gut/gut_cmdln.gd -- \
    -gconfig= \
    -gdir=res://tests/gut \
    -ginclude_subdirs \
    -gexit \
    -gdisable_colors \
    -gjunit_xml_file=res://build/gut/junit.xml || {
        status=$?
        echo "GUT failed with status $status" >&2
        exit "$status"
    }

for required_file in "$import_log" "$godot_log" "$junit"; do
    if [ ! -s "$required_file" ]; then
        echo "required GUT artifact is missing: $required_file" >&2
        exit 1
    fi
done

for log_file in "$import_log" "$godot_log"; do
    if grep -Eq '^(ERROR:|SCRIPT ERROR:)' "$log_file"; then
        echo "Godot error found in $log_file" >&2
        exit 1
    fi
done

python3 - "$junit" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()

    if "tests" in root.attrib:
        tests = int(root.attrib["tests"])
        failures = int(root.attrib.get("failures", 0))
        errors = int(root.attrib.get("errors", 0))
    else:
        suites = [child for child in root if child.tag.rsplit("}", 1)[-1] == "testsuite"]
        if not suites:
            raise ValueError("JUnit has no aggregate counts or child testsuites")
        tests = sum(int(suite.attrib.get("tests", 0)) for suite in suites)
        failures = sum(int(suite.attrib.get("failures", 0)) for suite in suites)
        errors = sum(int(suite.attrib.get("errors", 0)) for suite in suites)
except (ET.ParseError, OSError, TypeError, ValueError) as error:
    raise SystemExit(f"invalid JUnit {path}: {error}")

if tests <= 0:
    raise SystemExit(f"JUnit reported no tests: {path}")
if failures + errors != 0:
    raise SystemExit(
        f"JUnit reported {tests} tests, {failures} failures, and {errors} errors"
    )

print(f"GUT JUnit: {tests} tests, {failures} failures, {errors} errors")
PY
