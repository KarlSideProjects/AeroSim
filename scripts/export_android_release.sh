#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
signing_mode="${AEROSIM_ANDROID_SIGNING_MODE:-ci}"
if [ "$signing_mode" != "ci" ] && [ "$signing_mode" != "production" ]; then
    echo "unsupported Android signing mode: $signing_mode" >&2
    exit 1
fi
if [ -z "${GODOT_EXPORT_TEMPLATES_DIR:-}" ] && [ -z "${XDG_DATA_HOME:-}" ]; then
    echo "missing XDG_DATA_HOME for job-local Godot export templates" >&2
    exit 1
fi
if [ -z "${XDG_CONFIG_HOME:-}" ]; then
    echo "missing XDG_CONFIG_HOME for job-local Godot editor settings" >&2
    exit 1
fi
templates_dir="${GODOT_EXPORT_TEMPLATES_DIR:-$XDG_DATA_HOME/godot/export_templates/4.7.stable}"
release_lib="${AEROSIM_ANDROID_RELEASE_LIB:-bin/libaerosim_native.android.template_release.arm64.so}"
out_apk="${AEROSIM_ANDROID_OUT_APK:-build/release/AeroSim-android.apk}"
tool_root="${AEROSIM_TOOL_ROOT:-${RUNNER_TEMP:-/tmp}/aerosim-tools-${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-android-export}}"
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
keytool_bin="${AEROSIM_KEYTOOL:-keytool}"
apksigner_bin="${AEROSIM_ANDROID_APKSIGNER:-}"

if [ "$signing_mode" = "production" ]; then
    signing_keystore="${AEROSIM_ANDROID_RELEASE_KEYSTORE:-}"
    signing_user="${AEROSIM_ANDROID_RELEASE_KEY_ALIAS:-}"
    signing_password="${AEROSIM_ANDROID_RELEASE_KEYSTORE_PASS:-}"
    if [ -z "$signing_keystore" ] || [ -z "$signing_user" ] || [ -z "$signing_password" ]; then
        echo "missing production Android signing configuration" >&2
        exit 1
    fi
    if [ ! -s "$signing_keystore" ]; then
        echo "missing production Android keystore: $signing_keystore" >&2
        exit 1
    fi
else
    if [ -z "${AEROSIM_ANDROID_CI_KEYSTORE:-}" ] && [ -z "${RUNNER_TEMP:-}" ]; then
        echo "missing RUNNER_TEMP for job-local Android CI keystore" >&2
        exit 1
    fi
    signing_keystore="${AEROSIM_ANDROID_CI_KEYSTORE:-$tool_root/aerosim-ci-android.keystore}"
    signing_user="aerosim-ci"
    signing_password="android"
fi

if [ ! -s "$templates_dir/android_release.apk" ]; then
    echo "missing Godot Android export template: $templates_dir/android_release.apk" >&2
    exit 1
fi

if [ ! -s "$release_lib" ]; then
    echo "missing Android release GDExtension: $release_lib" >&2
    echo "run: GODOT_CPP_DIR=\$RUNNER_TEMP/aerosim-tools-\$GITHUB_RUN_ID-\$GITHUB_RUN_ATTEMPT-\$GITHUB_JOB/godot-cpp scons target=template_release platform=android arch=arm64 ANDROID_HOME=" >&2
    exit 1
fi

if [ -z "$android_sdk" ] || [ ! -d "$android_sdk/build-tools" ]; then
    echo "missing Android SDK build-tools; set ANDROID_HOME or ANDROID_SDK_ROOT" >&2
    exit 1
fi

if [ -z "$apksigner_bin" ]; then
    apksigner_bin="$(find "$android_sdk/build-tools" -maxdepth 2 -type f -name apksigner | sort -V | tail -n 1)"
fi

if [ ! -x "$apksigner_bin" ]; then
    echo "missing Android apksigner under $android_sdk/build-tools" >&2
    exit 1
fi

if [ "$signing_mode" = "ci" ] && ! command -v "$keytool_bin" >/dev/null 2>&1; then
    echo "missing keytool for Android CI test keystore generation" >&2
    exit 1
fi

if [ "$signing_mode" = "ci" ]; then
    keytool_path="$(command -v "$keytool_bin")"
    java_home="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$keytool_path")")")}"
else
    java_home="${JAVA_HOME:-}"
fi

mkdir -p "$tool_root" "$(dirname "$out_apk")" "$(dirname "$signing_keystore")"
out_apk="$(realpath -m "$out_apk")"
export_project="$tool_root/android-export-project"
rm -rf "$export_project"
mkdir -p "$export_project"
for source in "$PWD"/* "$PWD"/.[!.]* "$PWD"/..?*; do
    [ -e "$source" ] || continue
    name="$(basename "$source")"
    case "$name" in
        .git|.godot|.deps|build|export_presets.cfg)
            continue
            ;;
    esac
    ln -s "$source" "$export_project/$name"
done
cp export_presets.cfg "$export_project/export_presets.cfg"
cleanup_export_project() {
    rm -rf "$export_project"
}
trap cleanup_export_project EXIT

python3 - "$android_sdk" "$java_home" "$signing_keystore" <<'PY'
import os
from pathlib import Path
import sys

android_sdk, java_home, signing_keystore = sys.argv[1:]
settings_dir = Path(os.environ["XDG_CONFIG_HOME"]) / "godot"
settings_file = settings_dir / "editor_settings-4.7.tres"
settings_dir.mkdir(parents=True, exist_ok=True)

values = {
    "export/android/android_sdk_path": android_sdk,
    "export/android/java_sdk_path": java_home,
    "export/android/debug_keystore": signing_keystore,
}

if settings_file.exists():
    lines = settings_file.read_text(encoding="utf-8").splitlines()
else:
    lines = ['[gd_resource type="EditorSettings" format=3]', "", "[resource]"]

for key, value in values.items():
    replacement = f'{key} = "{value}"'
    for index, line in enumerate(lines):
        if line.startswith(f"{key} = "):
            lines[index] = replacement
            break
    else:
        if "[resource]" not in lines:
            lines.extend(["", "[resource]"])
        lines.append(replacement)

settings_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

export AEROSIM_ANDROID_PRESET_PASSWORD="$signing_password"
python3 - "$signing_keystore" "$signing_user" "$export_project/export_presets.cfg" <<'PY'
import os
from pathlib import Path
import sys

keystore, user, preset_path = sys.argv[1:]
password = os.environ["AEROSIM_ANDROID_PRESET_PASSWORD"]
path = Path(preset_path)
lines = path.read_text(encoding="utf-8").splitlines()
keys = {
    "keystore/debug": keystore,
    "keystore/release": keystore,
    "keystore/debug_user": user,
    "keystore/release_user": user,
    "keystore/debug_password": password,
    "keystore/release_password": password,
}
for index, line in enumerate(lines):
    for key, value in keys.items():
        if line.startswith(f'{key}='):
            lines[index] = f'{key}="{value}"'
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
unset AEROSIM_ANDROID_PRESET_PASSWORD

if [ "$signing_mode" = "ci" ] && [ ! -s "$signing_keystore" ]; then
    "$keytool_bin" -genkeypair \
        -keystore "$signing_keystore" \
        -storepass android \
        -alias aerosim-ci \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=AeroSim CI,O=AeroSim,C=TW" \
        >/dev/null
fi

rm -f "$out_apk"
"$godot_bin" --headless --path "$export_project" --export-release "Android" "$out_apk"

notice_file="$tool_root/THIRD_PARTY_NOTICES.txt"
signed_apk="$tool_root/AeroSim-android-with-notice.apk"
python3 scripts/check_licenses.py --notice-out "$notice_file"
python3 - "$out_apk" "$notice_file" <<'PY'
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZipFile

apk, notice = map(Path, sys.argv[1:])
with ZipFile(apk, "a", ZIP_DEFLATED) as archive:
    archive.write(notice, "assets/THIRD_PARTY_NOTICES.txt")
PY
rm -f "$signed_apk"
"$apksigner_bin" sign \
    --ks "$ci_keystore" \
    --ks-pass pass:android \
    --ks-key-alias aerosim-ci \
    --key-pass pass:android \
    --out "$signed_apk" \
    "$out_apk"
mv "$signed_apk" "$out_apk"

"$apksigner_bin" verify "$out_apk"
unzip -l "$out_apk" | grep -q "lib/arm64-v8a/$(basename "$release_lib")"
python3 scripts/check_release_artifacts.py "$out_apk"

signing_report="${AEROSIM_ANDROID_SIGNING_REPORT:-}"
if [ "$signing_mode" = "production" ] && [ -z "$signing_report" ]; then
    echo "missing production Android signing report path" >&2
    exit 1
fi
if [ -n "$signing_report" ]; then
    "$apksigner_bin" verify --print-certs "$out_apk" >"$signing_report"
    actual_fingerprint="$(awk -F': ' '/^Signer #1 certificate SHA-256 digest:/{print $2; exit}' "$signing_report")"
    if [ -z "$actual_fingerprint" ]; then
        echo "missing Android certificate SHA-256 fingerprint" >&2
        exit 1
    fi
    if [ "$signing_mode" = "production" ]; then
        expected_fingerprint="${AEROSIM_ANDROID_EXPECTED_CERT_SHA256:-}"
        normalize_fingerprint() {
            printf '%s' "$1" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]'
        }
        actual_fingerprint="$(normalize_fingerprint "$actual_fingerprint")"
        expected_fingerprint="$(normalize_fingerprint "$expected_fingerprint")"
        if ! [[ "$expected_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
            echo "missing or invalid expected production Android certificate SHA-256 fingerprint" >&2
            exit 1
        fi
        if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
            echo "production Android certificate SHA-256 fingerprint mismatch" >&2
            exit 1
        fi
    fi
fi
