#!/usr/bin/env python3
"""Contract checks for the issue-251 qualification runner design."""

from pathlib import Path
import unittest
import sys

sys.path.insert(0, str(Path(__file__).parent))
from run_gsp_idle_benchmark import compare_payloads


RUNNER = Path(__file__).with_name("run_gsp_idle_benchmark.sh")
IMPLEMENTATION = Path(__file__).with_name("run_gsp_idle_benchmark.py")


class GspIdleBenchmarkContractTest(unittest.TestCase):
    def test_runner_freezes_external_client_d_i_i_d_design(self) -> None:
        source = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn('RUN_ORDER = ["disabled", "authenticated-idle", "authenticated-idle", "disabled"]', source)
        self.assertIn("--ready-file", source)
        self.assertIn("--external-client", source)
        self.assertIn("telemetry_received", source)
        self.assertIn("pair_deltas", source)
        self.assertNotIn("--gsp-mode paired", source)

    def test_runner_keeps_each_60_second_run_as_experimental_unit(self) -> None:
        source = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn('"run_mean_physics_time_ms"', source)
        self.assertIn('"(I_a-D_a)/D_a"', source)
        self.assertIn('"(I_b-D_b)/D_b"', source)
        self.assertIn('"aggregate_pair_delta_percent"', source)
        self.assertIn('"percentiles_are_diagnostic_only"', source)

    def test_pair_comparison_uses_signed_run_means(self) -> None:
        payloads = {
            "D_a": {"samples_ms": [10.0, 10.0]},
            "I_a": {"samples_ms": [10.1, 10.1]},
            "I_b": {"samples_ms": [9.8, 9.8]},
            "D_b": {"samples_ms": [10.0, 10.0]},
        }
        comparison = compare_payloads(payloads, Path("build/test"), "a" * 40)
        self.assertAlmostEqual(comparison["primary"]["pair_deltas_percent"]["(I_a-D_a)/D_a"], 1.0)
        self.assertAlmostEqual(comparison["primary"]["pair_deltas_percent"]["(I_b-D_b)/D_b"], -2.0)
        self.assertAlmostEqual(comparison["primary"]["aggregate_pair_delta_percent"], -0.5)
        self.assertEqual(comparison["status"], "fail")


if __name__ == "__main__":
    unittest.main()
