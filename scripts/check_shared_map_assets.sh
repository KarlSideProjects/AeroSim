#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-.}"
scene_dir="$repo_root/levels/free_flight"
map_dir="$repo_root/config/maps"

for map_id in industrial_yard terrain3d_range; do
    if [[ ! -f "$scene_dir/$map_id.tscn" || ! -f "$map_dir/$map_id.json" ]]; then
        echo "shared Free Flight map is incomplete: $map_id" >&2
        exit 1
    fi
done

mobile_scene="$(find "$scene_dir" -maxdepth 1 -type f -name '*_mobile.tscn' -print -quit)"
if [[ -n "$mobile_scene" ]]; then
    echo "renderer-specific map scene is forbidden: $mobile_scene" >&2
    exit 1
fi

map_scenes="$(find "$scene_dir" -maxdepth 1 -type f -name '*.tscn' -printf '%f\n' | sort)"
if [[ "$map_scenes" != $'industrial_yard.tscn\nterrain3d_range.tscn' ]]; then
    echo "expected the two checked-in shared Free Flight scenes, found: ${map_scenes//$'\n'/ }" >&2
    exit 1
fi

if rg -n '(_mobile\.tscn|desktop_scene|mobile_scene)' "$map_dir" "$scene_dir" >/dev/null; then
    echo "map data must not select renderer-specific scene assets" >&2
    exit 1
fi

echo "shared Free Flight map asset check passed"
