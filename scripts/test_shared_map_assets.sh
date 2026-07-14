#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/levels/free_flight" "$fixture/config/maps"
touch "$fixture/levels/free_flight/industrial_yard.tscn" "$fixture/config/maps/industrial_yard.json"

"$repo_root/scripts/check_shared_map_assets.sh" "$fixture"

touch "$fixture/levels/free_flight/industrial_yard_mobile.tscn"
if "$repo_root/scripts/check_shared_map_assets.sh" "$fixture" >/dev/null 2>&1; then
    echo "shared map check accepted a mobile scene" >&2
    exit 1
fi
rm "$fixture/levels/free_flight/industrial_yard_mobile.tscn"

touch "$fixture/levels/free_flight/warehouse.tscn"
if "$repo_root/scripts/check_shared_map_assets.sh" "$fixture" >/dev/null 2>&1; then
    echo "shared map check accepted a second map scene" >&2
    exit 1
fi

echo "shared map asset tests passed"
