#!/usr/bin/env python3
"""Intent: the G0.1 runner measures the real Jolt scene, not a synthetic loop."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PerformanceRunnerTest(unittest.TestCase):
    def test_short_headed_run_records_jolt_samples_with_vsync_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "raw.json"
            godot_bin = os.environ.get("GODOT_BIN") or str(next((ROOT / ".deps" / "godot").glob("Godot*")))
            environment = os.environ | {"GODOT_BIN": godot_bin}
            if environment.get("AEROSIM_REQUIRED_GPU_ADAPTER", "NVIDIA") == "NVIDIA":
                environment |= {
                    "__NV_PRIME_RENDER_OFFLOAD": "1",
                    "__GLX_VENDOR_LIBRARY_NAME": "nvidia",
                    "__VK_LAYER_NV_optimus": "NVIDIA_only",
                }
            completed = subprocess.run(
                [
                    str(ROOT / "scripts" / "run_performance_benchmark.sh"),
                    "--warmup-seconds",
                    "0",
                    "--seconds",
                    "0.1",
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertFalse(output.with_name("raw.raw.json").exists())
            self.assertTrue(report["raw_samples_ms"])
            self.assertEqual(report["sample_count"], 24)
            self.assertGreater(len(set(report["raw_samples_ms"])), 1)
            self.assertEqual(report["measurement"]["sampling_source"], "EngineProfiler._tick")
            self.assertEqual(report["measurement"]["physics_engine"], "Jolt Physics")
            self.assertEqual(report["measurement"]["vsync_mode"], 0)

            candidate_output = Path(directory) / "candidate.json"
            candidate = subprocess.run(
                [
                    str(ROOT / "scripts" / "run_performance_benchmark.sh"),
                    "--warmup-seconds",
                    "0",
                    "--seconds",
                    "0.1",
                    "--effects",
                    "on",
                    "--baseline-report",
                    str(output),
                    "--output",
                    str(candidate_output),
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(candidate.returncode, 0, candidate.stderr)
            candidate_report = json.loads(candidate_output.read_text(encoding="utf-8"))
            self.assertIn("p99_delta_ms", candidate_report["comparison_to_baseline"])


if __name__ == "__main__":
    unittest.main()
