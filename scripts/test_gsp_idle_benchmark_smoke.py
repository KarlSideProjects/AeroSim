#!/usr/bin/env python3
"""Short real-time authenticated-idle smoke for the issue-251 runner."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_gsp_idle_benchmark import run_one


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-251-smoke-") as temporary:
        output_dir = Path(temporary)
        commit_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        run_one(output_dir, "smoke", "authenticated-idle", commit_sha, 0, 1, "smoke")
        raw = json.loads((output_dir / "smoke.raw.json").read_text(encoding="utf-8"))
        client = json.loads((output_dir / "smoke.external.raw.json").read_text(encoding="utf-8"))
        assert raw["monotonic_timing"]["measurement_elapsed_monotonic_seconds"] > 0.0
        assert client["open_throughout"]
        assert client["telemetry_received"] > 0
        print("GSP issue-251 real-time smoke: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
