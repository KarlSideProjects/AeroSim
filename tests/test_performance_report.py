#!/usr/bin/env python3
"""Intent: G0.1 reports keep raw timing evidence and enforce its frozen P99 gate."""

import math
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from performance_report import build_report, compare_reports, main


BASELINE_CPU = "AMD Ryzen 5 5600 6-Core Processor"
BASELINE_GPU = "NVIDIA GeForce GTX 1660 SUPER"
PINNED_PROVENANCE = {
    "godot_version": "4.7.stable.official.5b4e0cb0f",
    "godot_sha256": "a" * 64,
    "godot_cpp_revision": "ba0edfed90512ec64aba51d4295a3e7e30112f86",
    "gdextension_sha256": "b" * 64,
    "native_source_sha256": "c" * 64,
}


class PerformanceReportTest(unittest.TestCase):
    def test_nearest_rank_percentiles_preserve_raw_samples_and_gate_verdict(self):
        report = build_report(
            {
                "samples_ms": list(range(1, 101)),
                "render_cpu_samples_ms": list(range(101, 201)),
                "render_gpu_samples_ms": list(range(201, 301)),
                "benchmark_mode": "gate",
                "scenario": "effects_off",
                "video_adapter": BASELINE_GPU,
                **PINNED_PROVENANCE,
            },
            {"git_revision": "abc123", "cpu_model": BASELINE_CPU},
        )

        self.assertEqual(report["p95_ms"], 95.0)
        self.assertEqual(report["p99_ms"], 99.0)
        self.assertEqual(report["render_cpu_p95_ms"], 195.0)
        self.assertEqual(report["render_cpu_p99_ms"], 199.0)
        self.assertEqual(report["render_gpu_p95_ms"], 295.0)
        self.assertEqual(report["render_gpu_p99_ms"], 299.0)
        self.assertFalse(report["p99_within_limit"])
        self.assertTrue(report["gate_eligible"])
        self.assertEqual(report["gate_verdict"], "fail")
        self.assertEqual(report["raw_samples_ms"], list(range(1, 101)))
        self.assertEqual(report["measurement"]["scenario"], "effects_off")
        self.assertEqual(report["environment"]["git_revision"], "abc123")

    def test_rejects_empty_or_non_finite_measurements(self):
        with self.assertRaisesRegex(ValueError, "samples_ms"):
            build_report({"samples_ms": [], "benchmark_mode": "reference"}, {})
        with self.assertRaisesRegex(ValueError, "samples_ms"):
            build_report({"samples_ms": [1.0, math.nan], "benchmark_mode": "reference"}, {})

    def test_cli_writes_report_with_requested_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            report_path = directory_path / "report.json"
            chart_path = directory_path / "report.svg"
            raw_path.write_text(
                json.dumps({"samples_ms": [1.0, 2.0], "benchmark_mode": "reference"}),
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve().parents[1] / "scripts" / "performance_report.py"),
                    "--input",
                    str(raw_path),
                    "--output",
                    str(report_path),
                    "--git-revision",
                    "abc123",
                    "--chart-output",
                    str(chart_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            report_text = report_path.read_text(encoding="utf-8")
            self.assertEqual(report_text.count("\n"), 1)
            report = json.loads(report_text)
            self.assertEqual(report["environment"]["git_revision"], "abc123")
            self.assertFalse(report["gate_eligible"])
            self.assertNotIn("gate_verdict", report)
            self.assertIn("G0.1 physics frame time", chart_path.read_text(encoding="utf-8"))

    def test_cli_writes_failed_gate_evidence_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            report_path = directory_path / "report.json"
            raw_path.write_text(
                json.dumps(
                    {
                        "samples_ms": [4.0] * 100,
                        "benchmark_mode": "gate",
                        "video_adapter": BASELINE_GPU,
                        **PINNED_PROVENANCE,
                    }
                ),
                encoding="utf-8",
            )

            argv = [
                "performance_report.py",
                "--input",
                str(raw_path),
                "--output",
                str(report_path),
            ]
            with patch.object(sys, "argv", argv), patch(
                "performance_report._cpu_model", return_value=BASELINE_CPU
            ):
                returncode = main()

            self.assertEqual(returncode, 1)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["gate_verdict"], "fail")
            self.assertFalse(report["p99_within_limit"])

    def test_reference_and_smoke_results_cannot_claim_a_gate_pass(self):
        reference = build_report(
            {"samples_ms": [1.0, 2.0], "benchmark_mode": "reference"},
            {"git_revision": "abc123"},
        )
        smoke = build_report(
            {"samples_ms": [1.0, 2.0], "benchmark_mode": "smoke"},
            {"git_revision": "abc123"},
        )

        self.assertFalse(reference["gate_eligible"])
        self.assertTrue(reference["reference_only"])
        self.assertNotIn("gate_verdict", reference)
        self.assertEqual(reference["gate"], "G0.1-reference")
        self.assertFalse(smoke["gate_eligible"])
        self.assertFalse(smoke["reference_only"])
        self.assertNotIn("gate_verdict", smoke)
        self.assertEqual(smoke["gate"], "smoke")

    def test_gate_rejects_non_frozen_cpu_or_gpu(self):
        raw = {
            "samples_ms": [1.0, 2.0],
            "benchmark_mode": "gate",
            "video_adapter": BASELINE_GPU,
            **PINNED_PROVENANCE,
        }
        with self.assertRaisesRegex(ValueError, "frozen Ryzen 5 5600 and GTX 1660 SUPER"):
            build_report(raw, {"cpu_model": "AMD Ryzen 9 7945HX"})
        with self.assertRaisesRegex(ValueError, "frozen Ryzen 5 5600 and GTX 1660 SUPER"):
            build_report(
                raw | {"video_adapter": "NVIDIA GeForce RTX 4060 Ti"},
                {"cpu_model": BASELINE_CPU},
            )

    def test_comparison_reports_on_off_percentile_deltas(self):
        environment = {"git_revision": "abc123", "cpu_model": "reference"}
        common = {
            "benchmark_mode": "reference",
            "warmup_seconds": 10.0,
            "measured_seconds": 60.0,
            "physics_engine": "Jolt Physics",
            "physics_ticks_per_second": 240,
            "substep_hz": 1000,
            "vsync_mode": 0,
            "video_adapter": "NVIDIA GeForce RTX 4060 Ti",
            "rendering_method": "gl_compatibility",
            "godot_version": "4.7.stable",
            "godot_sha256": "godot-sha",
            "godot_cpp_revision": "godot-cpp-revision",
            "gdextension_sha256": "extension-sha",
            "native_source_sha256": "source-sha",
        }
        baseline = build_report(
            common | {"samples_ms": [1.0, 2.0], "scenario": "effects_off", "active_effects": []},
            environment,
        )
        candidate = build_report(
            common
            | {
                "samples_ms": [2.0, 4.0],
                "scenario": "effects_on",
                "active_effects": ["A3_drag", "A4_ground_effect"],
            },
            environment,
        )

        comparison = compare_reports(baseline, candidate)

        self.assertEqual(comparison["p95_delta_ms"], 2.0)
        self.assertEqual(comparison["p99_delta_ms"], 2.0)
        self.assertEqual(comparison["p99_delta_percent"], 100.0)

    def test_comparison_rejects_mixed_protocols_and_scenarios(self):
        environment = {"git_revision": "abc123", "cpu_model": "same"}
        baseline = build_report(
            {
                "samples_ms": [1.0, 2.0],
                "benchmark_mode": "smoke",
                "scenario": "effects_on",
                "measured_seconds": 0.1,
                "video_adapter": "llvmpipe",
            },
            environment,
        )
        candidate = build_report(
            {
                "samples_ms": [2.0, 4.0],
                "benchmark_mode": "reference",
                "scenario": "effects_on",
                "measured_seconds": 60.0,
                "video_adapter": "NVIDIA GeForce RTX 4060 Ti",
            },
            environment,
        )

        with self.assertRaisesRegex(ValueError, "effects_off baseline and effects_on candidate"):
            compare_reports(baseline, candidate)

        smoke_off = build_report(
            {
                "samples_ms": [1.0, 2.0],
                "benchmark_mode": "smoke",
                "scenario": "effects_off",
                "measured_seconds": 0.1,
                "video_adapter": "llvmpipe",
            },
            environment,
        )
        with self.assertRaisesRegex(ValueError, "benchmark_mode"):
            compare_reports(smoke_off, candidate)


if __name__ == "__main__":
    unittest.main()
