#!/usr/bin/env python3
"""Fail closed on GSP drone geometry that is unbundled, unhashed or unlicensed.

The check is deterministic and offline. It proves that

* every hardware configuration preset carries a complete geometry section,
* the geometry assets it names exist, are release-redistributable, and hash to
  the recorded sha256,
* those assets are installed by the GSP panel bundle and referenced by the
  panel, which loads only bundle-local files,
* the geometry classification the panel reports follows the same rule the
  browser applies, so `Real geometry` cannot be claimed without evidence.

Run with --write to refresh the recorded asset hashes after editing an asset.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "config/drone_schema.json"
ALLOWLIST = ROOT / "config/license_allowlist.json"
PRESET_DIRECTORY = ROOT / "config/drones"
LAUNCHER = ROOT / "common/gsp/gsp_launcher.gd"
PANEL = ROOT / "common/gsp/gsp_panel.html"
GEOMETRY_MODULE = ROOT / "common/gsp/assets/gsp_drone_geometry.js"
HARDWARE_CONFIG = ROOT / "common/flight/hardware_config.gd"
FIXTURE_PREFIX = "invalid_"
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
ASSET_PATH_RE = re.compile(r'"res://(common/gsp/assets/[^"]+)"')
PANEL_LOCAL_SRC_RE = re.compile(r'<script src="([^"]+)"></script>')
PANEL_REMOTE_RE = re.compile(r'(?:src|href)="(https?:)?//')
JS_LICENSES_RE = re.compile(r"const REDISTRIBUTABLE_LICENSES = \[(.*?)\];", re.DOTALL)
JS_EVIDENCE_RE = re.compile(r"const QUALIFYING_EVIDENCE_CLASSES = \[(.*?)\];", re.DOTALL)
# The renderer's required dimensions must stay the set the schema validates.
JS_KEY_LISTS = {
    "body_keys": re.compile(r"const BODY_KEYS = \[(.*?)\];", re.DOTALL),
    "motor_keys": re.compile(r"const MOTOR_KEYS = \[(.*?)\];", re.DOTALL),
    "propeller_keys": re.compile(r"const PROPELLER_DIMENSION_KEYS = \[(.*?)\];", re.DOTALL),
    "propeller_angle_keys": re.compile(r"const PROPELLER_ANGLE_KEYS = \[(.*?)\];", re.DOTALL),
}
# Kept in step with classify_geometry() in common/gsp/assets/gsp_drone_geometry.js.
QUALIFYING_EVIDENCE_CLASSES = ("manufacturer_cad", "manufacturer_drawing", "measured_specimen")


def quoted(source: str) -> list[str]:
    return re.findall(r'"([^"]+)"', source)


def text(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def classification_reasons(provenance: dict, allowed_licenses: set[str]) -> list[str]:
    """Mirror of the browser classifier, so both surfaces agree offline."""
    reasons: list[str] = []
    if not isinstance(provenance, dict):
        return ["missing_provenance"]
    if not text(provenance.get("model_source")) or not text(provenance.get("source_url")):
        reasons.append("missing_model_source")
    evidence = provenance.get("dimensional_evidence")
    evidence = evidence if isinstance(evidence, dict) else {}
    if evidence.get("evidence_class") not in QUALIFYING_EVIDENCE_CLASSES:
        reasons.append("unqualified_dimensional_evidence")
    documents = evidence.get("documents")
    documents = documents if isinstance(documents, list) else []
    if not documents or not all(
        isinstance(entry, dict) and text(entry.get("title")) and text(entry.get("url"))
        for entry in documents
    ):
        reasons.append("missing_dimensional_evidence_document")
    if provenance.get("redistribution") != "release":
        reasons.append("not_release_redistributable")
    license_entry = provenance.get("license")
    license_entry = license_entry if isinstance(license_entry, dict) else {}
    if license_entry.get("spdx") not in allowed_licenses:
        reasons.append("license_not_redistributable")
    if license_entry.get("attribution_required") is True and not text(license_entry.get("attribution")):
        reasons.append("missing_required_attribution")
    assets = provenance.get("assets")
    assets = assets if isinstance(assets, list) else []
    if not assets or not all(
        isinstance(asset, dict) and text(asset.get("path")) and HASH_RE.fullmatch(str(asset.get("sha256", "")))
        for asset in assets
    ):
        reasons.append("missing_asset_hash")
    return reasons


def check_dimensions(geometry: dict, spec: dict, label: str) -> list[str]:
    errors: list[str] = []
    identity = geometry.get("identity")
    if not isinstance(identity, dict) or not all(text(identity.get(key)) for key in ("designation", "airframe_class")):
        errors.append(f"{label}: geometry.identity is incomplete")
    dimension_range = spec["dimension_range"]
    for group, keys in (
        ("body", spec["body_keys"]),
        ("motor", spec["motor_keys"]),
        ("propeller", spec["propeller_keys"]),
    ):
        section = geometry.get(group)
        if not isinstance(section, dict):
            errors.append(f"{label}: geometry.{group} is missing")
            continue
        for key in keys:
            value = section.get(key)
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                errors.append(f"{label}: geometry.{group}.{key} is not numeric")
            elif not dimension_range["min"] <= float(value) <= dimension_range["max"]:
                errors.append(f"{label}: geometry.{group}.{key} out of range")
    propeller = geometry.get("propeller")
    if isinstance(propeller, dict):
        angle_range = spec["angle_range"]
        for key in spec["propeller_angle_keys"]:
            value = propeller.get(key)
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                errors.append(f"{label}: geometry.propeller.{key} is not numeric")
            elif not angle_range["min"] <= float(value) <= angle_range["max"]:
                errors.append(f"{label}: geometry.propeller.{key} out of range")
    return errors


def check_bundle(bundled: set[str]) -> list[str]:
    errors: list[str] = []
    panel = PANEL.read_text(encoding="utf-8")
    remote = PANEL_REMOTE_RE.search(panel)
    if remote:
        errors.append(f"{PANEL.name}: references a remote asset, which breaks offline load")
    referenced = {f"common/gsp/assets/{source.removeprefix('assets/')}"
                  for source in PANEL_LOCAL_SRC_RE.findall(panel) if source.startswith("assets/")}
    for source in sorted(referenced - bundled):
        errors.append(f"{PANEL.name}: {source} is referenced but not installed by GspLauncher")
    for source in sorted(bundled):
        if not (ROOT / source).is_file():
            errors.append(f"{LAUNCHER.name}: bundled asset is missing from the repository: {source}")
    if "common/gsp/assets/gsp_drone_geometry.js" not in referenced:
        errors.append(f"{PANEL.name}: the panel does not load the geometry package")
    return errors


def check_module_parity(allowed_licenses: set[str], spec: dict) -> list[str]:
    errors: list[str] = []
    module = GEOMETRY_MODULE.read_text(encoding="utf-8")
    for schema_key, pattern in JS_KEY_LISTS.items():
        match = pattern.search(module)
        if not match:
            errors.append(f"{GEOMETRY_MODULE.name}: cannot read its {schema_key} list")
            continue
        if sorted(quoted(match.group(1))) != sorted(spec[schema_key]):
            errors.append(
                f"{GEOMETRY_MODULE.name}: its {schema_key} list does not match "
                f"config/drone_schema.json geometry.{schema_key}"
            )
    licenses_match = JS_LICENSES_RE.search(module)
    evidence_match = JS_EVIDENCE_RE.search(module)
    if not licenses_match or not evidence_match:
        return [f"{GEOMETRY_MODULE.name}: cannot read its license or evidence policy"]
    if set(quoted(licenses_match.group(1))) != allowed_licenses:
        errors.append(
            f"{GEOMETRY_MODULE.name}: REDISTRIBUTABLE_LICENSES does not match config/license_allowlist.json"
        )
    if tuple(quoted(evidence_match.group(1))) != QUALIFYING_EVIDENCE_CLASSES:
        errors.append(
            f"{GEOMETRY_MODULE.name}: QUALIFYING_EVIDENCE_CLASSES does not match this check"
        )
    return errors


def asset_hash_pattern(asset_path: str) -> re.Pattern[str]:
    return re.compile(
        r'("path"\s*:\s*"' + re.escape(asset_path) + r'"\s*,\s*"sha256"\s*:\s*")[0-9a-f]{64}(")'
    )


def check_factory_default(write: bool) -> tuple[list[str], int]:
    """The fallback configuration must record the same asset hashes as the presets."""
    source = HARDWARE_CONFIG.read_text(encoding="utf-8")
    recorded = re.findall(r'"path"\s*:\s*"([^"]+)"\s*,\s*"sha256"', source)
    if not recorded:
        return [f"{HARDWARE_CONFIG.name}: FACTORY_DEFAULT records no geometry asset hash"], 0
    errors: list[str] = []
    rewrites = 0
    for asset_path in recorded:
        asset = ROOT / asset_path
        if not asset.is_file():
            errors.append(f"{HARDWARE_CONFIG.name}: FACTORY_DEFAULT names a missing asset: {asset_path}")
            continue
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        pattern = asset_hash_pattern(asset_path)
        match = pattern.search(source)
        if match is None:
            errors.append(f"{HARDWARE_CONFIG.name}: cannot read the recorded hash for {asset_path}")
            continue
        if match.group(0).endswith(digest + '"'):
            continue
        if not write:
            errors.append(
                f"{HARDWARE_CONFIG.name}: FACTORY_DEFAULT hash for {asset_path} is stale, found {digest}"
            )
            continue
        source = pattern.sub(lambda hit: hit.group(1) + digest + hit.group(2), source, count=1)
        rewrites += 1
        print(f"{HARDWARE_CONFIG.relative_to(ROOT)}: recorded sha256 for {asset_path}")
    if rewrites:
        HARDWARE_CONFIG.write_text(source, encoding="utf-8")
    return errors, rewrites


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preset", action="append", default=None,
                        help="check only these preset files (default: every shipped preset)")
    parser.add_argument("--write", action="store_true", help="refresh recorded asset sha256 hashes")
    parser.add_argument("--expect-nominal", action="store_true",
                        help="require every checked preset to report Nominal geometry")
    arguments = parser.parse_args()

    spec = json.loads(SCHEMA.read_text(encoding="utf-8"))["geometry"]
    allowed_licenses = set(json.loads(ALLOWLIST.read_text(encoding="utf-8"))["allowed_licenses"])
    bundled = set(ASSET_PATH_RE.findall(LAUNCHER.read_text(encoding="utf-8")))

    if arguments.preset:
        presets = [Path(entry) if Path(entry).is_absolute() else ROOT / entry for entry in arguments.preset]
    else:
        presets = sorted(
            path for path in PRESET_DIRECTORY.glob("*.json")
            if not path.name.startswith(FIXTURE_PREFIX)
        )
        if len(presets) < 2:
            print("expected at least two shipped presets to check", file=sys.stderr)
            return 1

    errors: list[str] = []
    errors.extend(check_bundle(bundled))
    errors.extend(check_module_parity(allowed_licenses, spec))
    factory_errors, rewrites = check_factory_default(arguments.write)
    errors.extend(factory_errors)

    for path in presets:
        label = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
        document = json.loads(path.read_text(encoding="utf-8"))
        geometry = document.get("geometry")
        if not isinstance(geometry, dict):
            errors.append(f"{label}: no geometry section")
            continue
        errors.extend(check_dimensions(geometry, spec, str(label)))

        provenance = geometry.get("provenance")
        if not isinstance(provenance, dict):
            errors.append(f"{label}: geometry.provenance is missing")
            continue
        if provenance.get("redistribution") != "release":
            errors.append(
                f"{label}: geometry is not release-redistributable: "
                f"redistribution={provenance.get('redistribution')!r}"
            )
        license_entry = provenance.get("license") if isinstance(provenance.get("license"), dict) else {}
        if license_entry.get("spdx") not in allowed_licenses:
            errors.append(
                f"{label}: geometry license is not on the release allowlist: {license_entry.get('spdx')!r}"
            )
        if license_entry.get("attribution_required") is True and not text(license_entry.get("attribution")):
            errors.append(f"{label}: geometry license requires attribution but records none")
        if provenance.get("dimensional_evidence", {}).get("evidence_class") not in spec["evidence_classes"]:
            errors.append(f"{label}: geometry evidence class is not recognized")

        assets = provenance.get("assets")
        if not isinstance(assets, list) or not assets:
            errors.append(f"{label}: geometry.provenance.assets is empty")
            continue
        for asset in assets:
            asset_path = str(asset.get("path", ""))
            resolved = ROOT / asset_path
            if not resolved.is_file():
                errors.append(f"{label}: geometry asset is missing: {asset_path}")
                continue
            if asset_path not in bundled:
                errors.append(f"{label}: geometry asset is not installed by GspLauncher: {asset_path}")
            digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
            recorded = str(asset.get("sha256", ""))
            if digest == recorded:
                continue
            if not arguments.write:
                errors.append(
                    f"{label}: geometry asset hash mismatch for {asset_path}: "
                    f"recorded {recorded}, found {digest}"
                )
                continue
            # Replace the recorded hash in place so preset formatting survives.
            source = path.read_text(encoding="utf-8")
            pattern = asset_hash_pattern(asset_path)
            replaced, count = pattern.subn(lambda match: match.group(1) + digest + match.group(2), source)
            if count == 1:
                path.write_text(replaced, encoding="utf-8")
                asset["sha256"] = digest
                rewrites += 1
                print(f"{label}: recorded sha256 for {asset_path}")
            else:
                errors.append(f"{label}: cannot rewrite the recorded hash for {asset_path}")

        reasons = classification_reasons(provenance, allowed_licenses)
        classification = "nominal" if reasons else "real"
        if arguments.expect_nominal and classification != "nominal":
            errors.append(f"{label}: expected Nominal geometry, computed {classification}")
        print(f"{label}: {classification} geometry" + (f" ({', '.join(reasons)})" if reasons else ""))

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(
        f"GSP drone geometry check passed: {len(presets)} presets, {len(bundled)} bundled assets"
        + (f", {rewrites} hashes rewritten" if rewrites else "")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
