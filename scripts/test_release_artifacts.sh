#!/usr/bin/env bash
set -euo pipefail

test -s docs/release_delivery_sop.md
grep -q "scripts/export_android_release.sh" docs/release_delivery_sop.md
test -x scripts/export_android_release.sh
grep -q '^textures/vram_compression/import_etc2_astc=true$' project.godot

python3 tests/test_release_notice_artifacts.py

mkdir -p build
artifact="$(mktemp build/release-artifact.XXXXXX)"
out_file="$(mktemp)"
err_file="$(mktemp)"
android_test_dir="$(mktemp -d build/android-release-test.XXXXXX)"
trap 'rm -rf "$android_test_dir"; rm -f "$artifact" "$out_file" "$err_file"' EXIT
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
fake_godot="$android_test_dir/godot"
cat >"$fake_godot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${!#}"
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
if [ "$1" = "verify" ] && [ "${2:-}" = "--print-certs" ]; then
    printf '%s\n' 'Signer #1 certificate SHA-256 digest: test-fingerprint'
fi
EOF
chmod +x "$fake_apksigner"
cp export_presets.cfg "$android_test_dir/export_presets.before"

XDG_CONFIG_HOME="$xdg_config_home" \
RUNNER_TEMP="$runner_temp" \
ANDROID_HOME="$android_test_dir/sdk" \
GODOT_EXPORT_TEMPLATES_DIR="$android_test_dir/templates" \
GODOT_BIN="$fake_godot" \
AEROSIM_ANDROID_SIGNING_MODE=production \
AEROSIM_ANDROID_RELEASE_KEYSTORE="$fake_keystore" \
AEROSIM_ANDROID_RELEASE_KEYSTORE_PASS=test-password \
AEROSIM_ANDROID_RELEASE_KEY_ALIAS=test-alias \
AEROSIM_ANDROID_RELEASE_LIB="$fake_lib" \
AEROSIM_ANDROID_OUT_APK="$android_test_dir/production.apk" \
AEROSIM_ANDROID_SIGNING_REPORT="$android_test_dir/production-signing.txt" \
scripts/export_android_release.sh

cmp "$android_test_dir/export_presets.before" export_presets.cfg
grep -q '^Signer #1 certificate SHA-256 digest:' "$android_test_dir/production-signing.txt"
