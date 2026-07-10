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
                    "--mode",
                    "smoke",
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
            self.assertTrue(output.with_suffix(".svg").is_file())
            self.assertTrue(report["raw_samples_ms"])
            self.assertEqual(report["sample_count"], 24)
            self.assertEqual(report["gate"], "smoke")
            self.assertFalse(report["gate_eligible"])
            self.assertNotIn("gate_verdict", report)
            self.assertGreater(len(set(report["raw_samples_ms"])), 1)
            measurement = report["measurement"]
            self.assertEqual(measurement["sampling_source"], "EngineProfiler._tick")
            self.assertEqual(measurement["physics_engine"], "Jolt Physics")
            self.assertEqual(measurement["vsync_mode"], 0)
            self.assertIn("4.7", measurement["godot_version"])
            self.assertRegex(measurement["godot_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(measurement["godot_cpp_revision"], r"^[0-9a-f]{40}$")
            self.assertRegex(measurement["gdextension_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(measurement["native_source_sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(measurement["active_effects"], [])

            candidate_output = Path(directory) / "candidate.json"
            candidate = subprocess.run(
                [
                    str(ROOT / "scripts" / "run_performance_benchmark.sh"),
                    "--mode",
                    "smoke",
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
            self.assertEqual(
                candidate_report["measurement"]["active_effects"],
                ["A3_drag", "A4_ground_effect"],
            )

    def test_reference_mode_rejects_shortened_gate_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            completed = subprocess.run(
                [
                    str(ROOT / "scripts" / "run_performance_benchmark.sh"),
                    "--mode",
                    "reference",
                    "--warmup-seconds",
                    "0",
                    "--seconds",
                    "0.1",
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                env=os.environ,
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 2, completed.stderr)
            self.assertIn("reference mode requires exactly 10s warmup and 60s measurement", completed.stderr)
            self.assertFalse(output.exists())

    def test_runner_fails_loudly_without_the_godot_cpp_source_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            missing_checkout = Path(directory) / "missing-godot-cpp"
            godot_bin = os.environ.get("GODOT_BIN") or str(next((ROOT / ".deps" / "godot").glob("Godot*")))
            completed = subprocess.run(
                [
                    str(ROOT / "scripts" / "run_performance_benchmark.sh"),
                    "--mode",
                    "smoke",
                    "--seconds",
                    "0.1",
                ],
                cwd=ROOT,
                env=os.environ | {
                    "GODOT_BIN": godot_bin,
                    "GODOT_CPP_DIR": str(missing_checkout),
                },
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 2, completed.stderr)
            self.assertIn("godot-cpp checkout is required", completed.stderr)


if __name__ == "__main__":
    unittest.main()
