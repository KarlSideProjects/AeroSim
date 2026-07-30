#!/usr/bin/env python3
"""Intent: the G0.1 runner measures the real Jolt scene, not a synthetic loop."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BENCHMARK_SOURCE = (ROOT / "tests" / "performance" / "physics_benchmark.gd").read_text(encoding="utf-8")


class PerformanceRunnerTest(unittest.TestCase):
    def test_lavapipe_smoke_uses_compatibility_without_downgrading_the_gate(self):
        runner_source = (ROOT / "scripts" / "run_performance_benchmark.sh").read_text(encoding="utf-8")

        self.assertIn('if [ "$benchmark_mode" = "smoke" ]; then', runner_source)
        self.assertIn('rendering_args=(--rendering-method gl_compatibility)', runner_source)
        self.assertIn('timeout 180s "$godot_bin" "${rendering_args[@]}"', runner_source)
        self.assertIn('func _hide_compatibility_grass_for_smoke(runtime: Node) -> void:', BENCHMARK_SOURCE)
        self.assertIn('_benchmark_mode != "smoke" or RenderingServer.get_current_rendering_method() != "gl_compatibility"', BENCHMARK_SOURCE)
        self.assertIn('particles.visible = false', BENCHMARK_SOURCE)

    def test_benchmark_source_activates_the_complete_effect_workload(self):
        for method in (
            "set_a3_drag_model",
            "set_a4_ground_effect_model",
            "set_a5_downwash_model",
            "set_a6_propwash_model",
            "set_dual_aircraft_positions",
            "step_dual_aircraft_simulation",
        ):
            self.assertIn(method, BENCHMARK_SOURCE)
        self.assertIn('"effect_evidence"', BENCHMARK_SOURCE)
        self.assertIn('"A5_downwash"', BENCHMARK_SOURCE)
        self.assertIn('"A6_propwash"', BENCHMARK_SOURCE)
        self.assertIn('"workload_attestation"', BENCHMARK_SOURCE)

    def test_effect_evidence_is_sticky_across_measurement_frames(self):
        self.assertIn('"A3_drag": {"observed": false, "magnitude": 0.0}', BENCHMARK_SOURCE)
        self.assertIn('var previous_evidence := effect_evidence.duplicate(true)', BENCHMARK_SOURCE)
        self.assertIn('maxf(drag_body.length(), float(previous_evidence.get("A3_drag"', BENCHMARK_SOURCE)
        self.assertIn('maxf(propwash.length(), float(previous_evidence.get("A6_propwash"', BENCHMARK_SOURCE)
        self.assertIn('effect_workload.process_physics_priority = 100', BENCHMARK_SOURCE)

    def test_a6_activation_uses_the_public_native_path_before_and_during_measurement(self):
        self.assertIn('func _activate_a6() -> bool:', BENCHMARK_SOURCE)
        self.assertIn('native.call("set_a6_propwash_model", enabled, 12.0, 2.0, 0.5)', BENCHMARK_SOURCE)
        self.assertIn('native.call("configure_wind", {', BENCHMARK_SOURCE)
        self.assertIn('native.call("wind_configuration")', BENCHMARK_SOURCE)
        self.assertIn('"steady_wind": Vector3.ZERO', BENCHMARK_SOURCE)
        self.assertIn('native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.866025403784, 0.0, -6.0, 0.0, 3.0, 0.0, -4.0)', BENCHMARK_SOURCE)
        self.assertIn('native.call("step_angle_mode", 240, 1000, 0.75, 0.0, 0.0, 0.0)', BENCHMARK_SOURCE)
        self.assertGreaterEqual(BENCHMARK_SOURCE.count('_activate_a6()'), 2)

    def test_zero_initial_propwash_does_not_fail_a6_setup(self):
        activation_start = BENCHMARK_SOURCE.index('    func _activate_a6() -> bool:')
        activation_end = BENCHMARK_SOURCE.index('    func _physics_process', activation_start)
        activation_source = BENCHMARK_SOURCE[activation_start:activation_end]
        self.assertNotIn('return not enabled or propwash.length() > 0.0', activation_source)
        self.assertIn('return true', activation_source)

    def test_activation_failure_latches_before_final_effect_gate(self):
        self.assertIn('var activation_failed := false', BENCHMARK_SOURCE)
        configure_start = BENCHMARK_SOURCE.index('func configure(native_runtime: Object, effects_enabled: bool) -> bool:')
        configure_end = BENCHMARK_SOURCE.index('    func _activate_a6() -> bool:', configure_start)
        configure_source = BENCHMARK_SOURCE[configure_start:configure_end]
        self.assertIn('enabled = effects_enabled\n        activation_failed = false', configure_source)

        physics_start = BENCHMARK_SOURCE.index('    func _physics_process(_delta: float) -> void:')
        physics_end = BENCHMARK_SOURCE.index('    func active_effects() -> Array[String]:', physics_start)
        physics_source = BENCHMARK_SOURCE[physics_start:physics_end]
        self.assertIn('if not _activate_a6():\n            activation_failed = true\n            return', physics_source)

        final_gate_start = BENCHMARK_SOURCE.index('if _effects == "on" and', physics_end)
        final_gate_end = BENCHMARK_SOURCE.index('\n\n    var output :=', final_gate_start)
        final_gate = BENCHMARK_SOURCE[final_gate_start:final_gate_end]
        self.assertIn('effect_workload.activation_failed', final_gate)
        self.assertIn('effect_workload.active_effects().size() != 4', final_gate)
        self.assertLess(
            final_gate.index('effect_workload.activation_failed'),
            final_gate.index('effect_workload.active_effects().size() != 4'),
        )

    def test_effect_workload_reconfigures_a3_drag_before_arming(self):
        configure_start = BENCHMARK_SOURCE.index('func configure(native_runtime: Object, effects_enabled: bool) -> bool:')
        configure_end = BENCHMARK_SOURCE.index('    func _activate_a6() -> bool:', configure_start)
        configure_source = BENCHMARK_SOURCE[configure_start:configure_end]
        self.assertIn('native.call("set_a3_drag_model", enabled, 0.0001, 0.0001, 0.00012)', configure_source)
        self.assertLess(
            configure_source.index('native.call("set_a3_drag_model", enabled, 0.0001, 0.0001, 0.00012)'),
            configure_source.index('native.call("arm_flight_control", 0.0)'),
        )

    def test_disabled_workload_keeps_control_path_for_apples_to_apples_timing(self):
        physics_index = BENCHMARK_SOURCE.index('func _physics_process(_delta: float) -> void:')
        activation_index = BENCHMARK_SOURCE.index('if not _activate_a6():', physics_index)
        dual_step_index = BENCHMARK_SOURCE.index('native.call("step_dual_aircraft_simulation"', physics_index)
        self.assertNotIn('if not enabled:\n            return', BENCHMARK_SOURCE[physics_index:])
        self.assertLess(activation_index, dual_step_index)

    def test_effect_evidence_resets_after_warmup_before_measurement(self):
        self.assertIn('func reset_effect_evidence() -> void:', BENCHMARK_SOURCE)
        warmup_index = BENCHMARK_SOURCE.index('for _frame in warmup_frames:')
        reset_index = BENCHMARK_SOURCE.rfind('effect_workload.reset_effect_evidence()')
        measurement_index = BENCHMARK_SOURCE.index('var first_measured_frame :=')
        self.assertGreater(reset_index, warmup_index)
        self.assertLess(reset_index, measurement_index)

    def test_benchmark_installs_a_valid_license_before_quick_fly(self):
        self.assertIn('class BenchmarkLicenseProvider:', BENCHMARK_SOURCE)
        self.assertIn('"status": "online_valid"', BENCHMARK_SOURCE)
        self.assertIn('func _install_deterministic_valid_license(runtime: Node) -> void:', BENCHMARK_SOURCE)
        self.assertLess(
            BENCHMARK_SOURCE.index('_install_deterministic_valid_license(runtime)'),
            BENCHMARK_SOURCE.index('runtime.quick_fly()'),
        )

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
            if "lvp_icd.json" in environment.get("VK_ICD_FILENAMES", ""):
                self.assertEqual(measurement["rendering_method"], "gl_compatibility")
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
                    # A6 needs a short motor-lag warmup; keep the measured smoke window at 0.1s.
                    "--warmup-seconds",
                    "1.0",
                    "--seconds",
                    "0.1",
                    "--effects",
                    "on",
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
            self.assertEqual(
                candidate_report["measurement"]["active_effects"],
                ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"],
            )
            self.assertTrue(all(
                evidence["observed"]
                for evidence in candidate_report["measurement"]["effect_evidence"].values()
            ))

            repeat_output = Path(directory) / "repeat.json"
            repeat = subprocess.run(
                [
                    str(ROOT / "scripts" / "run_performance_benchmark.sh"),
                    "--mode",
                    "smoke",
                    # Match the candidate warmup so repeat evidence covers delayed A6 activation.
                    "--warmup-seconds",
                    "1.0",
                    "--seconds",
                    "0.1",
                    "--effects",
                    "on",
                    "--output",
                    str(repeat_output),
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(repeat.returncode, 0, repeat.stderr)
            repeat_report = json.loads(repeat_output.read_text(encoding="utf-8"))
            self.assertEqual(
                repeat_report["measurement"]["active_effects"],
                candidate_report["measurement"]["active_effects"],
            )
            repeat_evidence = repeat_report["measurement"]["effect_evidence"]
            candidate_evidence = candidate_report["measurement"]["effect_evidence"]
            self.assertEqual(repeat_evidence.keys(), candidate_evidence.keys())
            for effect_name in candidate_evidence:
                self.assertEqual(
                    repeat_evidence[effect_name]["observed"],
                    candidate_evidence[effect_name]["observed"],
                )
                if effect_name == "A5_downwash":
                    self.assertLess(repeat_evidence[effect_name]["force_y_newtons"], 0.0)
                    self.assertLess(candidate_evidence[effect_name]["force_y_newtons"], 0.0)
                else:
                    self.assertGreater(repeat_evidence[effect_name]["magnitude"], 0.0)
                    self.assertGreater(candidate_evidence[effect_name]["magnitude"], 0.0)

    def test_default_gate_mode_rejects_shortened_gate_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
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
                env=os.environ,
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 2, completed.stderr)
            self.assertIn("gate mode requires exactly 10s warmup and 60s measurement", completed.stderr)
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
            self.assertIn("godot-cpp source is required", completed.stderr)


if __name__ == "__main__":
    unittest.main()
