#!/usr/bin/env python3
"""Fail if the vendored Terrain3D region data drifts from its recorded hashes.

`assets/third_party/terrain3d_demo/demo/data/` holds upstream bytes and nothing
else. The authoring pass reads it and writes to `assets/maps/terrain3d_range/`,
which is what keeps the SHA-256 record in `assets/third_party/terrain3d/
asset_notes.md` meaningful.

Opening the map in the Godot editor is enough to break that: the Terrain3D
plugin re-saves region files it has loaded, and the rewritten bytes look like an
ordinary edit in `git status`. This check turns that into a red build instead of
a silent change, and pins the notes and the files to each other so neither can
be updated alone.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "assets/third_party/terrain3d_demo/demo/data"
NOTES = ROOT / "assets/third_party/terrain3d/asset_notes.md"
REGION_PATTERN = re.compile(r"`(terrain3d_[0-9_-]+\.res)` `([0-9a-f]{64})`")


def recorded_hashes() -> dict[str, str]:
    try:
        text = NOTES.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"cannot read the asset notes: {NOTES}: {error}")
    recorded = dict(REGION_PATTERN.findall(text))
    if not recorded:
        raise SystemExit(f"the asset notes record no region hashes: {NOTES}")
    return recorded


def main() -> int:
    recorded = recorded_hashes()
    errors: list[str] = []

    present = sorted(path.name for path in DATA_DIR.glob("terrain3d_*.res"))
    missing = sorted(set(recorded) - set(present))
    unrecorded = sorted(set(present) - set(recorded))
    for name in missing:
        errors.append(f"recorded region is missing from the vendored directory: {name}")
    for name in unrecorded:
        errors.append(f"vendored region has no recorded hash in the asset notes: {name}")

    for name in sorted(set(recorded) & set(present)):
        digest = hashlib.sha256((DATA_DIR / name).read_bytes()).hexdigest()
        if digest != recorded[name]:
            errors.append(
                f"vendored region was modified: {name}\n"
                f"    recorded {recorded[name]}\n"
                f"    actual   {digest}\n"
                "    This directory is upstream bytes only. If the Godot editor rewrote it,\n"
                "    restore the file; if the upstream pin really moved, update the notes in\n"
                "    the same commit."
            )

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"third-party Terrain3D region integrity check passed ({len(present)} regions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
