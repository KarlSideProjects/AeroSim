#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
templates_dir="${GODOT_EXPORT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/4.7.stable}"
release_lib="bin/libaerosim_native.linux.template_release.x86_64.so"
out_dir="build/release/AeroSim-linux"
out_zip="build/release/AeroSim-linux.zip"

if [ ! -s "$templates_dir/linux_release.x86_64" ]; then
    echo "missing Godot Linux export template: $templates_dir/linux_release.x86_64" >&2
    exit 1
fi

if [ ! -s "$release_lib" ]; then
    echo "missing Linux release GDExtension: $release_lib" >&2
    echo "run: GODOT_CPP_DIR=.deps/godot-cpp scons target=template_release platform=linux" >&2
    exit 1
fi

rm -rf "$out_dir" "$out_zip"
mkdir -p "$out_dir"
"$godot_bin" --headless --path . --export-release "Linux Desktop" "$out_dir/AeroSim.x86_64"
chmod +x "$out_dir/AeroSim.x86_64"

python3 - <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path("build/release/AeroSim-linux")
out = Path("build/release/AeroSim-linux.zip")
with ZipFile(out, "w", ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(root.parent))
PY

python3 scripts/check_release_artifacts.py "$out_zip"
