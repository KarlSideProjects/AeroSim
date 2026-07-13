#!/usr/bin/env bash
set -euo pipefail

python_bin="${PYTHON_BIN:-python3}"
if [ "$($python_bin -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" != "3.11" ]; then
    echo "license server checks require Python 3.11" >&2
    exit 1
fi

venv="build/license-venv"
rm -rf "$venv"
"$python_bin" -m venv "$venv"
"$venv/bin/python" -m pip install --require-hashes -r license_server/requirements.lock
"$venv/bin/python" -m pip check
"$venv/bin/python" -m pip list --format=json > build/license-runtime.json
"$venv/bin/python" scripts/check_license_dependencies.py \
    --installed-json build/license-runtime.json
"$venv/bin/python" -m unittest tests.test_license_dependencies
