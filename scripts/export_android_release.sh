#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
templates_dir="${GODOT_EXPORT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/4.7.stable}"
release_lib="bin/libaerosim_native.android.template_release.arm64.so"
out_apk="build/release/AeroSim-android.apk"
ci_keystore=".deps/aerosim-ci-android.keystore"
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

if [ ! -s "$templates_dir/android_release.apk" ]; then
    echo "missing Godot Android export template: $templates_dir/android_release.apk" >&2
    exit 1
fi

if [ ! -s "$release_lib" ]; then
    echo "missing Android release GDExtension: $release_lib" >&2
    echo "run: GODOT_CPP_DIR=.deps/godot-cpp scons target=template_release platform=android arch=arm64 ANDROID_HOME=" >&2
    exit 1
fi

if [ -z "$android_sdk" ] || [ ! -d "$android_sdk/build-tools" ]; then
    echo "missing Android SDK build-tools; set ANDROID_HOME or ANDROID_SDK_ROOT" >&2
    exit 1
fi

if ! command -v keytool >/dev/null 2>&1; then
    echo "missing keytool for Android CI test keystore generation" >&2
    exit 1
fi

mkdir -p build/release .deps
touch build/.gdignore .deps/.gdignore

if [ ! -s "$ci_keystore" ]; then
    keytool -genkeypair \
        -keystore "$ci_keystore" \
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
"$godot_bin" --headless --path . --export-release "Android" "$out_apk"

python3 scripts/check_release_artifacts.py "$out_apk"
