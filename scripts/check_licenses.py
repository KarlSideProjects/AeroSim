#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import sys


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

    with open(args.manifest, encoding="utf-8") as file:
        dependencies = json.load(file)["dependencies"]

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
