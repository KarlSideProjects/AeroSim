#!/usr/bin/env bash

validate_native_provenance() {
    local native_provenance="${AEROSIM_NATIVE_PROVENANCE:-build/native_debug_artifact.json}"
    local provenance_values
    provenance_values="$(python3 - "$native_provenance" "$(git rev-parse HEAD)" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(f"native artifact provenance is missing: {path}")
try:
    receipt = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"native artifact provenance is invalid: {path}: {error}")
required = ("commit_sha", "gdextension_path", "gdextension_sha256", "native_source_sha256")
if any(not isinstance(receipt.get(key), str) or not receipt[key] for key in required):
    raise SystemExit(f"native artifact provenance is incomplete: {path}")
if receipt["commit_sha"] != sys.argv[2]:
    raise SystemExit(f"native artifact provenance is stale for HEAD: {path}")
expected_extension = "bin/libaerosim_native.linux.template_debug.x86_64.so"
if receipt["gdextension_path"] != expected_extension:
    raise SystemExit(f"native artifact provenance must name the fixed debug GDExtension: {path}")
extension = Path(expected_extension)
if not extension.is_file() or hashlib.sha256(extension.read_bytes()).hexdigest() != receipt["gdextension_sha256"]:
    raise SystemExit(f"native artifact provenance does not match the debug GDExtension: {path}")
digest = hashlib.sha256()
for source in [Path("SConstruct"), *sorted(Path("src/native").rglob("*"))]:
    if source.is_file():
        digest.update(f"{hashlib.sha256(source.read_bytes()).hexdigest()}  {source}\n".encode())
if digest.hexdigest() != receipt["native_source_sha256"]:
    raise SystemExit(f"native artifact provenance is stale for native sources: {path}")
print(receipt["commit_sha"])
print(receipt["gdextension_sha256"])
print(receipt["native_source_sha256"])
PY
)"
    AEROSIM_NATIVE_PROVENANCE="$native_provenance"
    AEROSIM_NATIVE_PROVENANCE_COMMIT_SHA="$(printf '%s\n' "$provenance_values" | sed -n '1p')"
    AEROSIM_NATIVE_PROVENANCE_GDEXTENSION_SHA256="$(printf '%s\n' "$provenance_values" | sed -n '2p')"
    AEROSIM_NATIVE_PROVENANCE_NATIVE_SOURCE_SHA256="$(printf '%s\n' "$provenance_values" | sed -n '3p')"
    export AEROSIM_NATIVE_PROVENANCE AEROSIM_NATIVE_PROVENANCE_COMMIT_SHA
    export AEROSIM_NATIVE_PROVENANCE_GDEXTENSION_SHA256 AEROSIM_NATIVE_PROVENANCE_NATIVE_SOURCE_SHA256
}
