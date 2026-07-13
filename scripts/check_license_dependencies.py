#!/usr/bin/env python3
"""Fail closed when the license server lock, install, and notices diverge."""

import argparse
import json
from pathlib import Path
import re
import sys


EXPECTED = {
    "cffi": ("2.0.0", "MIT"),
    "cryptography": ("49.0.0", "Apache-2.0"),
    "pycparser": ("3.0", "BSD-3-Clause"),
    "pyjwt": ("2.13.0", "MIT"),
}
BOOTSTRAP_PACKAGES = {"pip", "setuptools", "wheel"}
PIN_RE = re.compile(r"([A-Za-z0-9_.-]+)==([^\s\\]+)\s*\\?$")
HASH_RE = re.compile(r"--hash=sha256:([0-9a-f]{64})\s*\\?$")


def normalized(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def read_lock(path: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    hashes: dict[str, set[str]] = {}
    current = None
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        hash_match = HASH_RE.fullmatch(line)
        if hash_match:
            if current is None:
                raise ValueError(f"hash without package at line {line_number}")
            hashes[current].add(hash_match.group(1))
            continue
        pin_match = PIN_RE.fullmatch(line)
        if not pin_match:
            raise ValueError(f"unsupported lock entry at line {line_number}")
        current = normalized(pin_match.group(1))
        if current in pins:
            raise ValueError(f"duplicate locked package: {current}")
        pins[current] = pin_match.group(2)
        hashes[current] = set()

    unhashed = sorted(name for name in pins if not hashes[name])
    if unhashed:
        raise ValueError(f"locked packages missing sha256 hashes: {', '.join(unhashed)}")
    return pins


def read_manifest(path: Path) -> dict[str, tuple[str, str]]:
    dependencies = json.loads(path.read_text(encoding="utf-8"))["dependencies"]
    result = {}
    for dependency in dependencies:
        package = dependency.get("python_package")
        if not package:
            continue
        name = normalized(package)
        if name in result:
            raise ValueError(f"duplicate Python manifest package: {name}")
        notice = dependency.get("notice")
        if not isinstance(notice, str) or not notice.strip():
            raise ValueError(f"Python manifest package has no notice: {name}")
        result[name] = (str(dependency.get("version", "")), dependency.get("license", ""))
    return result


def read_installed(path: Path) -> dict[str, str]:
    packages = json.loads(path.read_text(encoding="utf-8"))
    return {
        normalized(package["name"]): str(package["version"])
        for package in packages
        if normalized(package["name"]) not in BOOTSTRAP_PACKAGES
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", default="license_server/requirements.lock")
    parser.add_argument("--manifest", default="third_party/licenses.json")
    parser.add_argument("--installed-json", required=True)
    args = parser.parse_args()

    try:
        lock = read_lock(Path(args.lock))
        manifest = read_manifest(Path(args.manifest))
        installed = read_installed(Path(args.installed_json))
    except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"license runtime closure invalid: {error}", file=sys.stderr)
        return 1

    expected_versions = {name: contract[0] for name, contract in EXPECTED.items()}
    if lock.get("cffi") != "2.0.0":
        print("cffi must be exactly 2.0.0", file=sys.stderr)
        return 1
    if lock != expected_versions:
        print("license runtime lock differs from frozen closure", file=sys.stderr)
        return 1
    if manifest != EXPECTED:
        print("license runtime manifest differs from frozen closure", file=sys.stderr)
        return 1
    if installed != lock:
        print("installed runtime closure differs from lock", file=sys.stderr)
        return 1

    print(f"license runtime closure passed: {len(lock)} dependencies")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
