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


BASELINE_CPU = "AMD Ryzen 9 7945HX with Radeon Graphics"
BASELINE_GPU = "NVIDIA GeForce RTX 4060 Ti"
BASELINE_OS_RELEASE = "Ubuntu 26.04 LTS"
BASELINE_NVIDIA_DRIVER = "580.159.03"
BASELINE_ENVIRONMENT = {
    "cpu_model": BASELINE_CPU,
    "os_release": BASELINE_OS_RELEASE,
    "nvidia_driver_version": BASELINE_NVIDIA_DRIVER,
}
PINNED_PROVENANCE = {
    "godot_version": "4.7.stable.official.5b4e0cb0f",
    "godot_sha256": "f85bbc6b15e22416c7d797cd60b63286dd67b9cb13498847056c18520ae55a75",
    "godot_cpp_revision": "ba0edfed90512ec64aba51d4295a3e7e30112f86",
    "gdextension_sha256": "b" * 64,
    "native_source_sha256": "c" * 64,
}
G3_7_WORKLOAD_ATTESTATION = {
    "workload_id": "G3.7-A3-A6-public-native-v1",
    "effect_paths": {
        "A3_drag": "telemetry_snapshot.drag_body_n",
        "A4_ground_effect": "telemetry_snapshot.ground_effect_gain",
        "A5_downwash": "step_dual_aircraft_simulation.downwash_force_y_newtons",
        "A6_propwash": "telemetry_snapshot.propwash_disturbance_rad_s2",
    },
    "control_path": "sync_flight_state -> step_angle_mode -> step_dual_aircraft_simulation",
    "evidence_scope": "measurement_frames",
}
VALID_EFFECT_EVIDENCE = {
    "A3_drag": {"observed": True, "magnitude": 1.0},
    "A4_ground_effect": {"observed": True, "magnitude": 1.0},
    "A5_downwash": {"observed": True, "force_y_newtons": -1.0},
    "A6_propwash": {"observed": True, "magnitude": 1.0},
}
G3_7_SAMPLE_COUNT = 14_400


def g37_samples(value):
    return [value] * G3_7_SAMPLE_COUNT


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
            {"git_revision": "abc123", **BASELINE_ENVIRONMENT},
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
            ), patch(
                "performance_report._os_release", return_value=BASELINE_OS_RELEASE
            ), patch(
                "performance_report._nvidia_driver_version", return_value=BASELINE_NVIDIA_DRIVER
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
        with self.assertRaisesRegex(ValueError, "frozen Ryzen 9 7945HX and RTX 4060 Ti"):
            build_report(raw, BASELINE_ENVIRONMENT | {"cpu_model": "AMD Ryzen 5 5600 6-Core Processor"})
        with self.assertRaisesRegex(ValueError, "frozen Ryzen 9 7945HX and RTX 4060 Ti"):
            build_report(
                raw | {"video_adapter": "NVIDIA GeForce GTX 1660 SUPER"},
                BASELINE_ENVIRONMENT,
            )
        with self.assertRaisesRegex(ValueError, "pinned Godot/godot-cpp"):
            build_report(
                raw | {"godot_sha256": "a" * 64},
                BASELINE_ENVIRONMENT,
            )

    def test_gate_rejects_wrong_frozen_os_or_nvidia_driver(self):
        raw = {
            "samples_ms": [1.0, 2.0],
            "benchmark_mode": "gate",
            "video_adapter": BASELINE_GPU,
            **PINNED_PROVENANCE,
        }

        with self.assertRaisesRegex(ValueError, "Ubuntu 26.04 LTS and NVIDIA driver 580.159.03"):
            build_report(raw, BASELINE_ENVIRONMENT | {"os_release": "Ubuntu 24.04.4 LTS"})
        with self.assertRaisesRegex(ValueError, "Ubuntu 26.04 LTS and NVIDIA driver 580.159.03"):
            build_report(raw, BASELINE_ENVIRONMENT | {"nvidia_driver_version": "570.133.07"})

    def test_comparison_reports_on_off_percentile_deltas(self):
        environment = {"git_revision": "abc123", **BASELINE_ENVIRONMENT}
        common = {
            "benchmark_mode": "gate",
            "warmup_seconds": 10.0,
            "measured_seconds": 60.0,
            "physics_engine": "Jolt Physics",
            "physics_ticks_per_second": 240,
            "substep_hz": 1000,
            "vsync_mode": 0,
            "video_adapter": BASELINE_GPU,
            "rendering_method": "forward_plus",
            "sampling_source": "EngineProfiler._tick",
            "workload_attestation": G3_7_WORKLOAD_ATTESTATION,
            **PINNED_PROVENANCE,
        }
        baseline = build_report(
            common | {"samples_ms": g37_samples(1.0), "scenario": "effects_off", "active_effects": []},
            environment,
        )
        candidate = build_report(
            common
            | {
                "samples_ms": g37_samples(2.0),
                "scenario": "effects_on",
                "active_effects": ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
                "effect_evidence": VALID_EFFECT_EVIDENCE,
            },
            environment,
        )

        comparison = compare_reports(baseline, candidate)

        self.assertEqual(comparison["p95_delta_ms"], 1.0)
        self.assertEqual(comparison["p99_delta_ms"], 1.0)
        self.assertEqual(comparison["p99_delta_percent"], 100.0)

    def test_g37_passes_at_absolute_and_relative_boundaries(self):
        environment = {"git_revision": "abc123", **BASELINE_ENVIRONMENT}
        common = {
            "benchmark_mode": "gate",
            "warmup_seconds": 10.0,
            "measured_seconds": 60.0,
            "physics_engine": "Jolt Physics",
            "physics_ticks_per_second": 240,
            "substep_hz": 1000,
            "vsync_mode": 0,
            "video_adapter": BASELINE_GPU,
            "rendering_method": "forward_plus",
            "sampling_source": "EngineProfiler._tick",
            "workload_attestation": G3_7_WORKLOAD_ATTESTATION,
            **PINNED_PROVENANCE,
        }
        baseline = build_report(
            common | {"samples_ms": g37_samples(2.5), "scenario": "effects_off", "active_effects": []},
            environment,
        )
        candidate = build_report(
            common
            | {
                "samples_ms": g37_samples(3.0),
                "scenario": "effects_on",
                "active_effects": ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
                "effect_evidence": VALID_EFFECT_EVIDENCE,
            },
            environment,
        )

        comparison = compare_reports(baseline, candidate)

        self.assertEqual(comparison["g3_7_verdict"], "pass")
        self.assertTrue(comparison["g3_7_p99_within_limit"])
        self.assertTrue(comparison["g3_7_increase_within_limit"])

        with self.assertRaisesRegex(ValueError, "p99_ms does not match"):
            compare_reports(baseline, candidate | {"p99_ms": 3.01})
        relative_baseline = build_report(
            common | {"samples_ms": g37_samples(1.0), "scenario": "effects_off", "active_effects": []},
            environment,
        )
        relative_fail = compare_reports(relative_baseline, candidate)
        self.assertEqual(relative_fail["g3_7_verdict"], "fail")
        self.assertFalse(relative_fail["g3_7_increase_within_limit"])

    def test_g37_rejects_tampered_or_forged_production_reports(self):
        environment = {"git_revision": "abc123", **BASELINE_ENVIRONMENT}
        common = {
            "benchmark_mode": "gate",
            "warmup_seconds": 10.0,
            "measured_seconds": 60.0,
            "physics_engine": "Jolt Physics",
            "physics_ticks_per_second": 240,
            "substep_hz": 1000,
            "vsync_mode": 0,
            "video_adapter": BASELINE_GPU,
            "rendering_method": "forward_plus",
            "sampling_source": "EngineProfiler._tick",
            "workload_attestation": G3_7_WORKLOAD_ATTESTATION,
            **PINNED_PROVENANCE,
        }
        baseline = build_report(
            common | {"samples_ms": g37_samples(2.5), "scenario": "effects_off", "active_effects": []},
            environment,
        )
        candidate = build_report(
            common
            | {
                "samples_ms": g37_samples(3.0),
                "scenario": "effects_on",
                "active_effects": ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
                "effect_evidence": VALID_EFFECT_EVIDENCE,
            },
            environment,
        )

        for report, other in ((baseline, candidate), (candidate, baseline)):
            with self.assertRaises(ValueError):
                compare_reports(report | {"p99_ms": 3.01}, other)
            with self.assertRaises(ValueError):
                compare_reports(report | {"gate_eligible": False}, other)
            with self.assertRaises(ValueError):
                compare_reports(report | {"raw_samples_ms": [99.0]}, other)
            with self.assertRaises(ValueError):
                compare_reports(report | {"sample_count": True}, other)

        with self.assertRaises(ValueError):
            compare_reports(candidate | {"raw_samples_ms": [3.000000000002]}, baseline)

        forged_protocol = (
            ("warmup_seconds", 9.0),
            ("measured_seconds", 59.0),
            ("physics_ticks_per_second", 120),
            ("substep_hz", 999),
            ("vsync_mode", 1),
            ("sampling_source", "manual"),
        )
        for key, value in forged_protocol:
            with self.assertRaises(ValueError):
                compare_reports(
                    baseline | {"measurement": baseline["measurement"] | {key: value}},
                    candidate | {"measurement": candidate["measurement"] | {key: value}},
                )

        with self.assertRaises(ValueError):
            compare_reports(baseline | {"gate_verdict": "fail"}, candidate)

        forged_environment = BASELINE_ENVIRONMENT | {"cpu_model": "forged production CPU"}
        with self.assertRaises(ValueError):
            compare_reports(
                baseline | {"environment": forged_environment},
                candidate | {"environment": forged_environment},
            )

        forged_measurement = baseline["measurement"] | {"video_adapter": "NVIDIA GeForce RTX 5090"}
        with self.assertRaises(ValueError):
            compare_reports(
                baseline | {"measurement": forged_measurement},
                candidate | {"measurement": candidate["measurement"] | {"video_adapter": "NVIDIA GeForce RTX 5090"}},
            )

        invalid_evidence = [
            {effect: {"observed": True} for effect in VALID_EFFECT_EVIDENCE},
            {
                "A3_drag": {"observed": True, "magnitude": 0.0},
                "A4_ground_effect": {"observed": True, "magnitude": math.nan},
                "A5_downwash": {"observed": True, "force_y_newtons": 0.0},
                "A6_propwash": {"observed": True, "magnitude": -1.0},
            },
        ]
        for evidence in invalid_evidence:
            tampered_measurement = candidate["measurement"] | {"effect_evidence": evidence}
            with self.assertRaises(ValueError):
                compare_reports(baseline, candidate | {"measurement": tampered_measurement})

        for metric in ("render_cpu_p95_ms", "render_cpu_p99_ms", "render_gpu_p95_ms", "render_gpu_p99_ms"):
            comparison = compare_reports(baseline, candidate | {metric: math.nan})
            self.assertEqual(comparison["g3_7_verdict"], "pass")
            self.assertFalse(any(key.startswith("render_") for key in comparison))

        with self.assertRaises(ValueError):
            compare_reports(
                baseline | {"measurement": baseline["measurement"] | {"workload_attestation": {}}},
                candidate,
            )
        missing_attestation = {
            key: value for key, value in candidate["measurement"].items() if key != "workload_attestation"
        }
        with self.assertRaises(ValueError):
            compare_reports(baseline, candidate | {"measurement": missing_attestation})

        with self.assertRaises(ValueError):
            compare_reports(baseline | {"p95_ms": 2.500000000001}, candidate)

    def test_g37_rejects_nonproduction_reports(self):
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
            "rendering_method": "forward_plus",
            "godot_version": "4.7.stable",
            "godot_sha256": "godot-sha",
            "godot_cpp_revision": "godot-cpp-revision",
            "gdextension_sha256": "extension-sha",
            "native_source_sha256": "source-sha",
        }
        for mode in ("reference", "smoke"):
            baseline = build_report(
                common | {"benchmark_mode": mode, "samples_ms": [2.5], "scenario": "effects_off", "active_effects": []},
                environment,
            )
            candidate = build_report(
                common
                | {
                    "benchmark_mode": mode,
                    "samples_ms": [3.0],
                    "scenario": "effects_on",
                    "active_effects": ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
                    "effect_evidence": VALID_EFFECT_EVIDENCE,
                },
                environment,
            )

            with self.assertRaisesRegex(ValueError, "G3.7 requires passing G0.1 production reports"):
                compare_reports(baseline, candidate)

    def test_g37_fails_closed_for_missing_incompatible_or_zero_baseline(self):
        environment = {"git_revision": "abc123", **BASELINE_ENVIRONMENT}
        common = {
            "benchmark_mode": "gate",
            "warmup_seconds": 10.0,
            "measured_seconds": 60.0,
            "physics_engine": "Jolt Physics",
            "physics_ticks_per_second": 240,
            "substep_hz": 1000,
            "vsync_mode": 0,
            "video_adapter": BASELINE_GPU,
            "rendering_method": "forward_plus",
            "sampling_source": "EngineProfiler._tick",
            "workload_attestation": G3_7_WORKLOAD_ATTESTATION,
            **PINNED_PROVENANCE,
        }
        baseline = build_report(
            common | {"samples_ms": g37_samples(2.0), "scenario": "effects_off", "active_effects": []},
            environment,
        )
        candidate_raw = common | {
            "samples_ms": g37_samples(2.1),
            "scenario": "effects_on",
            "active_effects": ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
            "effect_evidence": VALID_EFFECT_EVIDENCE,
        }
        candidate = build_report(candidate_raw, environment)

        with self.assertRaisesRegex(ValueError, "raw_samples_ms"):
            compare_reports({"environment": environment, "scenario": "effects_off", "sample_count": 1, "measurement": {}}, candidate)
        with self.assertRaisesRegex(ValueError, "sample_count"):
            compare_reports(baseline, candidate | {"sample_count": 2})
        with self.assertRaisesRegex(ValueError, "sample_count must be 14400"):
            compare_reports(baseline | {"sample_count": 1, "raw_samples_ms": [2.0]}, candidate)
        with self.assertRaisesRegex(ValueError, "p99_ms does not match"):
            compare_reports(baseline | {"p99_ms": 0.0}, candidate)

    def test_g37_requires_observed_enabled_effects(self):
        environment = {"git_revision": "abc123", **BASELINE_ENVIRONMENT}
        common = {
            "benchmark_mode": "gate",
            "warmup_seconds": 10.0,
            "measured_seconds": 60.0,
            "physics_engine": "Jolt Physics",
            "physics_ticks_per_second": 240,
            "substep_hz": 1000,
            "vsync_mode": 0,
            "video_adapter": BASELINE_GPU,
            "rendering_method": "forward_plus",
            "sampling_source": "EngineProfiler._tick",
            "workload_attestation": G3_7_WORKLOAD_ATTESTATION,
            **PINNED_PROVENANCE,
        }
        baseline = build_report(
            common | {"samples_ms": g37_samples(2.0), "scenario": "effects_off", "active_effects": []},
            environment,
        )
        candidate = build_report(
            common
            | {
                "samples_ms": g37_samples(2.1),
                "scenario": "effects_on",
                "active_effects": ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
            },
            environment,
        )

        with self.assertRaisesRegex(ValueError, "effect evidence"):
            compare_reports(baseline, candidate)

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
        with self.assertRaisesRegex(ValueError, "G3.7 requires passing G0.1 production reports"):
            compare_reports(smoke_off, candidate)


if __name__ == "__main__":
    unittest.main()
