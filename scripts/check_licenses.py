#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import sys


GYM_PYBULLET_DRONES = "gym-pybullet-drones"
GYM_PYBULLET_DRONES_CONTRACT = (
    Path(__file__).resolve().parents[1] / "oracles" / "gym_pybullet_drones_contract.json"
)
DEFAULT_MANIFEST = Path(__file__).resolve().parents[1] / "third_party" / "licenses.json"


def gym_pybullet_drones_attribution_error(
    dependencies: list[dict],
    required: bool,
) -> str | None:
    entries = [
        dependency
        for dependency in dependencies
        if dependency.get("name") == GYM_PYBULLET_DRONES
    ]
    if not entries:
        if required:
            return "required attribution missing: gym-pybullet-drones"
        return None
    if len(entries) != 1:
        return "gym-pybullet-drones attribution invalid: duplicate manifest entries"

    contract = json.loads(GYM_PYBULLET_DRONES_CONTRACT.read_text(encoding="utf-8"))
    entry = entries[0]
    scope = entry.get("attribution_scope")
    required_scope_terms = (
        "AeroSim source-code/formula ports",
        "does not claim redistribution rights",
        "papers/PDFs",
        "experimental datasets",
        "constants/parameter tables",
    )
    notice = entry.get("notice", "")
    if (
        entry.get("license") != "MIT"
        or entry.get("homepage") != contract["repository_url"]
        or entry.get("version") != contract["commit"]
        or not isinstance(scope, str)
        or not all(term in scope for term in required_scope_terms)
        or "Copyright (c) 2020 Jacopo Panerati" not in notice
        or "Permission is hereby granted" not in notice
    ):
        return "gym-pybullet-drones attribution invalid"
    return None


def write_notice(path: str, dependencies: list[dict]) -> None:
    lines = [
        "AeroSim third-party notices",
        "",
        "Generated from third_party/licenses.json.",
        "",
    ]
    for dependency in dependencies:
        lines.extend([
            dependency["name"],
            f"Version: {dependency['version']}",
            f"License: {dependency['license']}",
        ])
        if dependency.get("homepage"):
            lines.append(f"Homepage: {dependency['homepage']}")
        if dependency.get("attribution_scope"):
            lines.append(f"Attribution scope: {dependency['attribution_scope']}")
        if dependency.get("notice"):
            lines.extend(["", dependency["notice"]])
        lines.extend(["", "---", ""])

    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="third_party/licenses.json")
    parser.add_argument("--allowlist", default="config/license_allowlist.json")
    parser.add_argument("--notice-out")
    args = parser.parse_args()

    with open(args.allowlist, encoding="utf-8") as file:
        allowed = set(json.load(file)["allowed_licenses"])

    manifest_path = Path(args.manifest).resolve()
    with open(manifest_path, encoding="utf-8") as file:
        dependencies = json.load(file)["dependencies"]

    attribution_error = gym_pybullet_drones_attribution_error(
        dependencies,
        required=manifest_path == DEFAULT_MANIFEST,
    )
    if attribution_error:
        print(attribution_error, file=sys.stderr)
        return 1

    violations = [
        dependency for dependency in dependencies
        if dependency["license"] not in allowed
    ]

    if violations:
        for dependency in violations:
            print(
                f"license denied: {dependency['name']} "
                f"{dependency['version']} ({dependency['license']})",
                file=sys.stderr,
            )
        return 1

    if args.notice_out:
        write_notice(args.notice_out, dependencies)
        print(f"notice generated: {args.notice_out}")

    print(f"license scan passed: {len(dependencies)} dependencies")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
