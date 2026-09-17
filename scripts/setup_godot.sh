#!/usr/bin/env bash
set -euo pipefail

mode="${1:?usage: setup_godot.sh editor|templates}"
[[ "$mode" == editor || "$mode" == templates ]] || exit 2
: "${AEROSIM_TOOL_ROOT:?}" "${GITHUB_ENV:?}"
godot_bin="${GODOT_BIN:-$(command -v godot || true)}"
if [[ -z "$godot_bin" ]]; then
    godot_bin="$(find "$HOME/godot" -maxdepth 1 -type f -name 'Godot_v*-stable_linux.x86_64' 2>/dev/null | sort -V | tail -n 1 || true)"
fi
if [[ -z "$godot_bin" ]]; then
    archive="$AEROSIM_TOOL_ROOT/godot.zip"
    scripts/download_release_asset.sh \
        https://github.com/godotengine/godot/releases/download/4.7-stable/Godot_v4.7-stable_linux.x86_64.zip \
        "$archive" sha256 0b1a6c54c2c619c12e169fe9241edda4b81080b519451cec2984bf0d2c6cb73c
    unzip -qo "$archive" -d "$AEROSIM_TOOL_ROOT/godot"
    godot_bin="$AEROSIM_TOOL_ROOT/godot/Godot_v4.7-stable_linux.x86_64"
fi
godot_bin="$(realpath "$(command -v "$godot_bin")")"
[[ "$godot_bin" != *$'\n'* && "$godot_bin" != *$'\r'* ]] || exit 1
version="$("$godot_bin" --version)"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?\.stable(\.|$) ]]; then
    echo "Expected a stable Godot version >= 4.7, got: $version" >&2
    exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
template_version="$major.$minor${BASH_REMATCH[3]}.stable"
if (( 10#$major < 4 || (10#$major == 4 && 10#$minor < 7) )); then
    echo "Godot >= 4.7 is required, got: $version" >&2
    exit 1
fi
if [[ "$mode" == editor ]]; then
    printf 'GODOT_BIN=%s\n' "$godot_bin" >> "$GITHUB_ENV"
    echo "Using Godot $version at $godot_bin"
    exit 0
fi

: "${XDG_DATA_HOME:?}"
templates_dir="$XDG_DATA_HOME/godot/export_templates/$template_version"
source_dir="${GODOT_EXPORT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/$template_version}"
if [[ ! -s "$source_dir/linux_release.x86_64" || ! -s "$source_dir/linux_debug.x86_64" ]]; then
    release="${template_version%.stable}-stable"
    filename="Godot_v${release}_export_templates.tpz"
    release_url="https://github.com/godotengine/godot/releases/download/$release"
    sums="$AEROSIM_TOOL_ROOT/SHA512-SUMS.txt"
    curl -fsSL --retry 4 "$release_url/SHA512-SUMS.txt" -o "$sums"
    digest="$(awk -v name="$filename" '$2 == name {print $1}' "$sums")"
    [[ "$digest" =~ ^[a-fA-F0-9]{128}$ ]] || { echo "Missing official template checksum" >&2; exit 1; }
    archive="$AEROSIM_TOOL_ROOT/godot-export-templates.tpz"
    AEROSIM_DOWNLOAD_PARALLELISM=16 scripts/download_release_asset.sh "$release_url/$filename" "$archive" sha512 "$digest"
    unzip -qo "$archive" -d "$AEROSIM_TOOL_ROOT/godot-export-templates"
    source_dir="$AEROSIM_TOOL_ROOT/godot-export-templates/templates"
fi
if [[ "$(cat "$source_dir/version.txt")" != "$template_version" ]]; then
    echo "Export templates do not match Godot $template_version: $source_dir" >&2
    exit 1
fi
mkdir -p "$templates_dir"
if [[ "$(realpath "$source_dir")" != "$(realpath "$templates_dir")" ]]; then
    cp -a "$source_dir/." "$templates_dir/"
fi
echo "Using export templates $template_version in $templates_dir"
