#!/usr/bin/env python3
import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="third_party/licenses.json")
    parser.add_argument("--allowlist", default="config/license_allowlist.json")
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

    print(f"license scan passed: {len(dependencies)} dependencies")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
