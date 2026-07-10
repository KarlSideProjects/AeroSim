#!/usr/bin/env python3
"""Intent: G0.1 reports keep raw timing evidence and enforce its frozen P99 gate."""

import math
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from performance_report import build_report, compare_reports


class PerformanceReportTest(unittest.TestCase):
    def test_nearest_rank_percentiles_preserve_raw_samples_and_gate_verdict(self):
        report = build_report(
            {
                "samples_ms": list(range(1, 101)),
                "render_cpu_samples_ms": list(range(101, 201)),
                "render_gpu_samples_ms": list(range(201, 301)),
                "benchmark_mode": "gate",
                "scenario": "effects_off",
            },
            {"git_revision": "abc123", "cpu_model": "reference"},
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
            build_report({"samples_ms": [], "benchmark_mode": "gate"}, {})
        with self.assertRaisesRegex(ValueError, "samples_ms"):
            build_report({"samples_ms": [1.0, math.nan], "benchmark_mode": "gate"}, {})

    def test_cli_writes_report_with_requested_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            report_path = directory_path / "report.json"
            chart_path = directory_path / "report.svg"
            raw_path.write_text(
                json.dumps({"samples_ms": [1.0, 2.0], "benchmark_mode": "gate"}),
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
            self.assertEqual(report["gate_verdict"], "pass")
            self.assertIn("G0.1 physics frame time", chart_path.read_text(encoding="utf-8"))

    def test_cli_writes_failed_gate_evidence_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            report_path = directory_path / "report.json"
            raw_path.write_text(
                json.dumps({"samples_ms": [4.0] * 100, "benchmark_mode": "gate"}),
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
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 1, completed.stderr)
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

    def test_comparison_reports_on_off_percentile_deltas(self):
        environment = {"git_revision": "abc123", "cpu_model": "reference"}
        baseline = build_report({"samples_ms": [1.0, 2.0], "benchmark_mode": "reference"}, environment)
        candidate = build_report({"samples_ms": [2.0, 4.0], "benchmark_mode": "reference"}, environment)

        comparison = compare_reports(baseline, candidate)

        self.assertEqual(comparison["p95_delta_ms"], 2.0)
        self.assertEqual(comparison["p99_delta_ms"], 2.0)
        self.assertEqual(comparison["p99_delta_percent"], 100.0)


if __name__ == "__main__":
    unittest.main()
