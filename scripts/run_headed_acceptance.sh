#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
out_dir="build/headed"
use_xvfb=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --xvfb)
            use_xvfb=1
            shift
            ;;
        --out-dir)
            out_dir="$2"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$use_xvfb" -eq 1 ]; then
    lavapipe_icd="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
    test -r "$lavapipe_icd"
    command -v xvfb-run >/dev/null
    export VK_ICD_FILENAMES="$lavapipe_icd"
    launcher=(xvfb-run -a --server-args="-screen 0 1280x720x24")
else
    launcher=()
fi

mkdir -p "$out_dir"
mkdir -p .godot
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg
rm -f "$out_dir"/*.png "$out_dir/report.json"
"${launcher[@]}" "$godot_bin" --path . --resolution 1280x720 \
    --script res://tests/headed/headed_acceptance.gd -- --out-dir "$out_dir"
