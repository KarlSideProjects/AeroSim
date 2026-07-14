#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-.}"
scene_dir="$repo_root/levels/free_flight"
map_dir="$repo_root/config/maps"

if [[ ! -f "$scene_dir/industrial_yard.tscn" ]]; then
    echo "Industrial Yard scene is missing: $scene_dir/industrial_yard.tscn" >&2
    exit 1
fi

mobile_scene="$(find "$scene_dir" -maxdepth 1 -type f -name '*_mobile.tscn' -print -quit)"
if [[ -n "$mobile_scene" ]]; then
    echo "renderer-specific map scene is forbidden: $mobile_scene" >&2
    exit 1
fi

map_scenes="$(find "$scene_dir" -maxdepth 1 -type f -name '*.tscn' -printf '%f\n' | sort)"
if [[ "$map_scenes" != "industrial_yard.tscn" ]]; then
    echo "expected exactly one shared Free Flight scene, found: ${map_scenes//$'\n'/ }" >&2
    exit 1
fi

if [[ ! -f "$map_dir/industrial_yard.json" ]]; then
    echo "Industrial Yard descriptor is missing: $map_dir/industrial_yard.json" >&2
    exit 1
fi

if rg -n '(_mobile\.tscn|desktop_scene|mobile_scene)' "$map_dir" "$scene_dir" >/dev/null; then
    echo "map data must not select renderer-specific scene assets" >&2
    exit 1
fi

echo "shared Industrial Yard map asset check passed"
