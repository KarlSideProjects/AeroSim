#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
if [ -z "${GODOT_EXPORT_TEMPLATES_DIR:-}" ] && [ -z "${XDG_DATA_HOME:-}" ]; then
    echo "missing XDG_DATA_HOME for job-local Godot export templates" >&2
    exit 1
fi
templates_dir="${GODOT_EXPORT_TEMPLATES_DIR:-$XDG_DATA_HOME/godot/export_templates/4.7.stable}"
release_lib="bin/libaerosim_native.windows.template_release.x86_64.dll"
out_dir="build/release/AeroSim-windows"
out_zip="build/release/AeroSim-windows.zip"

if [ ! -s "$templates_dir/windows_release_x86_64.exe" ]; then
    echo "missing Godot Windows export template: $templates_dir/windows_release_x86_64.exe" >&2
    exit 1
fi

if [ ! -s "$release_lib" ]; then
    echo "missing Windows release GDExtension: $release_lib" >&2
    echo "run: GODOT_CPP_DIR=\$RUNNER_TEMP/aerosim-tools-\$GITHUB_RUN_ID-\$GITHUB_RUN_ATTEMPT-\$GITHUB_JOB/godot-cpp scons target=template_release platform=windows use_mingw=yes" >&2
    exit 1
fi

rm -rf "$out_dir" "$out_zip"
mkdir -p "$out_dir" .deps
touch build/.gdignore .deps/.gdignore
"$godot_bin" --headless --path . --export-release "Windows Desktop" "$out_dir/AeroSim.exe"
python3 scripts/check_licenses.py --notice-out "$out_dir/THIRD_PARTY_NOTICES.txt"

python3 - <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path("build/release/AeroSim-windows")
out = Path("build/release/AeroSim-windows.zip")
with ZipFile(out, "w", ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(root.parent))
PY

python3 scripts/check_release_artifacts.py "$out_zip"
