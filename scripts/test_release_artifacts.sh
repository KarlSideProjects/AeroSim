#!/usr/bin/env bash
set -euo pipefail

test -s docs/release_delivery_sop.md
grep -q "release-android/AeroSim-android.apk" docs/release_delivery_sop.md
grep -q "must never be delivered" docs/release_delivery_sop.md
test -x scripts/export_android_release.sh
grep -q '^textures/vram_compression/import_etc2_astc=true$' project.godot
grep -q '^rendering_device/fallback_to_opengl3=true$' project.godot

python3 tests/test_release_notice_artifacts.py

mkdir -p build
artifact="$(mktemp build/release-artifact.XXXXXX)"
out_file="$(mktemp)"
err_file="$(mktemp)"
android_test_dir="$(mktemp -d build/android-release-test.XXXXXX)"
relative_production_apk="build/release/AeroSim-android-production.apk"
relative_signing_report="build/release/AeroSim-android-production-signing.txt"
trap 'rm -rf "$android_test_dir"; rm -f "$artifact" "$out_file" "$err_file" "$relative_production_apk" "$relative_signing_report"' EXIT
xdg_config_home="$android_test_dir/xdg-config"
xdg_data_home="$android_test_dir/xdg-data"
runner_temp="$android_test_dir/runner-temp"
mkdir -p "$runner_temp"

printf 'artifact' >"$artifact"
python3 scripts/check_release_artifacts.py "$artifact" >"$out_file"
grep -q "$artifact: 8 bytes" "$out_file"

if python3 scripts/check_release_artifacts.py build/does-not-exist.zip >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing release artifact unexpectedly passed" >&2
    exit 1
fi

grep -q "missing artifact: build/does-not-exist.zip" "$err_file"

if env -u GODOT_EXPORT_TEMPLATES_DIR -u XDG_DATA_HOME \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing XDG_DATA_HOME unexpectedly passed" >&2
    exit 1
fi

grep -q "missing XDG_DATA_HOME for job-local Godot export templates" "$err_file"

if env -u XDG_CONFIG_HOME \
    XDG_DATA_HOME="$xdg_data_home" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing XDG_CONFIG_HOME unexpectedly passed" >&2
    exit 1
fi

grep -q "missing XDG_CONFIG_HOME for job-local Godot editor settings" "$err_file"

if XDG_CONFIG_HOME="$xdg_config_home" \
    RUNNER_TEMP="$runner_temp" \
    GODOT_EXPORT_TEMPLATES_DIR=build/does-not-exist \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing Android export template unexpectedly passed" >&2
    exit 1
fi

grep -q "missing Godot Android export template: build/does-not-exist/android_release.apk" "$err_file"

mkdir -p "$android_test_dir/templates" "$android_test_dir/sdk/build-tools/35.0.1"
printf 'template' >"$android_test_dir/templates/android_release.apk"

if XDG_CONFIG_HOME="$xdg_config_home" \
    RUNNER_TEMP="$runner_temp" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing Android release GDExtension unexpectedly passed" >&2
    exit 1
fi

grep -q "missing Android release GDExtension: bin/libaerosim_native.android.template_release.arm64.so" "$err_file"

fake_lib="$android_test_dir/libaerosim_native.android.template_release.arm64.so"
printf 'native' >"$fake_lib"

if env -u ANDROID_HOME -u ANDROID_SDK_ROOT \
    XDG_CONFIG_HOME="$xdg_config_home" \
    RUNNER_TEMP="$runner_temp" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing Android SDK unexpectedly passed" >&2
    exit 1
fi

grep -q "missing Android SDK build-tools; set ANDROID_HOME or ANDROID_SDK_ROOT" "$err_file"

if XDG_CONFIG_HOME="$xdg_config_home" \
    RUNNER_TEMP="$runner_temp" \
    ANDROID_HOME="$android_test_dir/sdk" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing Android apksigner unexpectedly passed" >&2
    exit 1
fi

grep -q "missing Android apksigner under $android_test_dir/sdk/build-tools" "$err_file"

fake_apksigner="$android_test_dir/sdk/build-tools/35.0.1/apksigner"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_apksigner"
chmod +x "$fake_apksigner"

if XDG_CONFIG_HOME="$xdg_config_home" \
    RUNNER_TEMP="$runner_temp" \
    ANDROID_HOME="$android_test_dir/sdk" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
    AEROSIM_KEYTOOL="$android_test_dir/missing-keytool" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing keytool unexpectedly passed" >&2
    exit 1
fi

grep -q "missing keytool for Android CI test keystore generation" "$err_file"

if XDG_CONFIG_HOME="$xdg_config_home" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    AEROSIM_ANDROID_SIGNING_MODE=production \
    AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "missing production signing configuration unexpectedly passed" >&2
    exit 1
fi

grep -q "missing production Android signing configuration" "$err_file"

fake_keystore="$android_test_dir/release.keystore"
printf 'production-keystore' >"$fake_keystore"
java_home="$android_test_dir/java"
mkdir -p "$java_home"
fake_godot="$android_test_dir/godot"
cat >"$fake_godot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
project_path=""
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--path" ]; then
        project_path="$2"
        shift 2
        continue
    fi
    out="$1"
    shift
done
if [ -n "$project_path" ] && [[ "$out" != /* ]]; then
    out="$project_path/$out"
fi
python3 - "$out" "$AEROSIM_ANDROID_RELEASE_LIB" <<'PY'
from pathlib import Path
import sys
from zipfile import ZipFile

out, native_lib = map(Path, sys.argv[1:])
with ZipFile(out, "w") as archive:
    archive.write(native_lib, "lib/arm64-v8a/" + native_lib.name)
PY
EOF
chmod +x "$fake_godot"
cat >"$fake_apksigner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "sign" ]; then
    printf '%s\n' "$@" >"${AEROSIM_ANDROID_SIGN_ARGS:?}"
    input="${!#}"
    output=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--out" ]; then
            output="$2"
            shift 2
            continue
        fi
        shift
    done
    cp "$input" "$output"
    exit 0
fi
if [ "$1" = "verify" ] && [ "${2:-}" = "--print-certs" ]; then
    printf '%s\n' 'Signer #1 certificate SHA-256 digest: AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA'
fi
EOF
chmod +x "$fake_apksigner"

if env -u JAVA_HOME \
    XDG_CONFIG_HOME="$xdg_config_home" \
    RUNNER_TEMP="$runner_temp" \
    ANDROID_HOME="$android_test_dir/sdk" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    GODOT_BIN="$fake_godot" \
    AEROSIM_ANDROID_SIGNING_MODE=production \
    AEROSIM_ANDROID_RELEASE_KEYSTORE="$fake_keystore" \
    AEROSIM_ANDROID_RELEASE_KEYSTORE_PASS=test-password \
    AEROSIM_ANDROID_RELEASE_KEY_ALIAS=test-alias \
    AEROSIM_ANDROID_EXPECTED_CERT_SHA256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
    AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
    AEROSIM_ANDROID_OUT_APK="$android_test_dir/missing-java-home.apk" \
    AEROSIM_ANDROID_SIGNING_REPORT="$android_test_dir/missing-java-home-signing.txt" \
    AEROSIM_ANDROID_SIGN_ARGS="$android_test_dir/missing-java-home-sign-args.txt" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "production Android export without JAVA_HOME unexpectedly passed" >&2
    exit 1
fi

grep -q "missing JAVA_HOME for production Android export" "$err_file"
cp export_presets.cfg "$android_test_dir/export_presets.before"

XDG_CONFIG_HOME="$xdg_config_home" \
JAVA_HOME="$java_home" \
RUNNER_TEMP="$runner_temp" \
ANDROID_HOME="$android_test_dir/sdk" \
GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
GODOT_BIN="$fake_godot" \
AEROSIM_ANDROID_SIGNING_MODE=production \
AEROSIM_ANDROID_RELEASE_KEYSTORE="$fake_keystore" \
AEROSIM_ANDROID_RELEASE_KEYSTORE_PASS=test-password \
AEROSIM_ANDROID_RELEASE_KEY_ALIAS=test-alias \
AEROSIM_ANDROID_EXPECTED_CERT_SHA256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
AEROSIM_ANDROID_OUT_APK="$relative_production_apk" \
AEROSIM_ANDROID_SIGNING_REPORT="$relative_signing_report" \
AEROSIM_ANDROID_SIGN_ARGS="$android_test_dir/sign-args.txt" \
scripts/export_android_release.sh

cmp "$android_test_dir/export_presets.before" export_presets.cfg
grep -q '^Signer #1 certificate SHA-256 digest:' "$relative_signing_report"
grep -Fx -- "$fake_keystore" "$android_test_dir/sign-args.txt"
grep -Fx -- 'pass:test-password' "$android_test_dir/sign-args.txt"
grep -Fx -- 'test-alias' "$android_test_dir/sign-args.txt"

if XDG_CONFIG_HOME="$xdg_config_home" \
    JAVA_HOME="$java_home" \
    RUNNER_TEMP="$runner_temp" \
    ANDROID_HOME="$android_test_dir/sdk" \
    GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
    GODOT_BIN="$fake_godot" \
    AEROSIM_ANDROID_SIGNING_MODE=production \
    AEROSIM_ANDROID_RELEASE_KEYSTORE="$fake_keystore" \
    AEROSIM_ANDROID_RELEASE_KEYSTORE_PASS=test-password \
    AEROSIM_ANDROID_RELEASE_KEY_ALIAS=test-alias \
    AEROSIM_ANDROID_EXPECTED_CERT_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
    AEROSIM_ANDROID_OUT_APK="$android_test_dir/mismatched-production.apk" \
    AEROSIM_ANDROID_SIGNING_REPORT="$android_test_dir/mismatched-production-signing.txt" \
    AEROSIM_ANDROID_SIGN_ARGS="$android_test_dir/mismatched-sign-args.txt" \
    scripts/export_android_release.sh >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "mismatched production certificate unexpectedly passed" >&2
    exit 1
fi

grep -q "production Android certificate SHA-256 fingerprint mismatch" "$err_file"
cmp "$android_test_dir/export_presets.before" export_presets.cfg
