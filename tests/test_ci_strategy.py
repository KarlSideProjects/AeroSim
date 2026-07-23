#!/usr/bin/env python3
"""Intent: CI fails fast once per PR without weakening runtime evidence."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
PERFORMANCE_GPU_WORKFLOW = ROOT / ".github" / "workflows" / "performance-gpu.yml"
HEADED_RUNNER = ROOT / "scripts" / "run_headed_acceptance.sh"
HEADED_ACCEPTANCE = ROOT / "tests" / "headed" / "headed_acceptance.gd"
HEADLESS_RUNNER = ROOT / "scripts" / "run_headless_smoke.sh"
PERFORMANCE_RUNNER = ROOT / "scripts" / "run_performance_benchmark.sh"
GUT_RUNNER = ROOT / "scripts" / "run_gut_tests.sh"
ATOMIC_BOUNDARY_RUNNER = ROOT / "scripts" / "test_native_atomic_boundary.sh"
REPLAY_RUNNER = ROOT / "scripts" / "test_replay_integration.sh"
VERIFY_ISSUE_11 = ROOT / "scripts" / "verify_issue_11.sh"

FAKE_GODOT = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]

expected_fixed_fps = os.environ.get("FAKE_GODOT_EXPECT_FIXED_FPS")
if expected_fixed_fps is not None:
    if args.count("--fixed-fps") != 1:
        raise SystemExit(23)
    fixed_fps_index = args.index("--fixed-fps")
    if (
        fixed_fps_index + 1 >= len(args)
        or args[fixed_fps_index + 1] != expected_fixed_fps
    ):
        raise SystemExit(23)

if "--log-file" in args:
    log_path = Path(args[args.index("--log-file") + 1])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(os.environ.get("FAKE_GODOT_LOG", ""), encoding="utf-8")

runner_args = args[args.index("--") + 1:] if "--" in args else []

if "--out-dir" in runner_args:
    result_path = Path(runner_args[runner_args.index("--out-dir") + 1]) / "report.json"
    result_key = "passed"
    for screenshot in (
        "00_cold_start.png",
        "01_controller_confirmation.png",
        "02_keyboard_fallback.png",
        "03_takeoff.png",
        "04_paused.png",
        "05_reset.png",
        "06_exit.png",
        "07_channel_monitor_paused.png",
        "08_zh_tw_settings.png",
        "09_en_settings_roundtrip.png",
    ):
        (result_path.parent / screenshot).write_bytes(b"fake png")
else:
    result_path = Path(runner_args[runner_args.index("--output") + 1])
    csv_path = Path(runner_args[runner_args.index("--csv-output") + 1])
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.write_text("time_s\\n0\\n", encoding="utf-8")
    result_key = "completed"

mode = os.environ["FAKE_GODOT_RESULT"]
result = {} if mode == "missing" else {
    result_key: mode == "true",
    "provenance": {
        "commit_sha": os.environ.get("AEROSIM_HEADED_COMMIT_SHA", ""),
        "godot_version": "fake",
        "os": "fake",
        "display_driver": "fake",
        "gpu_adapter": "fake",
    },
    "locale_switches": [
        {"from": "en", "to": "zh_TW", "elapsed_us": 1000, "threshold_us": 100000},
    ],
}
result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.write_text(json.dumps(result), encoding="utf-8")
raise SystemExit(int(os.environ.get("FAKE_GODOT_EXIT", "0")))
"""


def job_body(workflow: str, name: str) -> str:
    remainder = workflow.split(f"  {name}:\n", 1)[1]
    return re.split(r"^  [a-z0-9-]+:\n", remainder, maxsplit=1, flags=re.MULTILINE)[0]


class CiStrategyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.linux_job = job_body(cls.workflow, "linux")

    def test_feature_branch_pushes_do_not_duplicate_pr_builds(self):
        with self.subTest(trigger="push only main"):
            self.assertIn("  push:\n    branches:\n      - main\n", self.workflow)
        with self.subTest(trigger="pull requests"):
            self.assertIn("  pull_request:\n", self.workflow)
        with self.subTest(trigger="manual runs"):
            self.assertIn("  workflow_dispatch:\n", self.workflow)

    def test_only_stale_runs_from_the_same_pr_are_cancelled(self):
        self.assertRegex(
            self.workflow,
            re.compile(
                r"^concurrency:\n"
                r"^  group: ci-\$\{\{ github\.event\.pull_request\.number \|\| github\.run_id \}\}\n"
                r"^  cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}$",
                re.MULTILINE,
            ),
        )

    def test_blocking_gut_runs_immediately_after_linux_debug_artifact_recording(self):
        match = re.search(
            re.compile(
                r"^      - name: Build GDExtension\n"
                r"^        run: scons target=template_debug platform=linux\n"
                r"\n"
                r"^      - name: Record Linux debug artifact provenance\n"
                r"(?:(?!^      - ).)*"
                r"\n"
                r"(?P<gut_step>^      - name: [^\n]*GUT[^\n]*\n"
                r"(?:(?!^      - ).)*(?=^      - |\Z))",
                re.MULTILINE | re.DOTALL,
            ),
            self.linux_job,
        )
        self.assertIsNotNone(match)
        gut_step = match.group("gut_step")
        with self.subTest(contract="blocking command"):
            self.assertRegex(
                gut_step,
                re.compile(r"^        run: scripts/run_gut_tests\.sh$", re.MULTILINE),
            )
        with self.subTest(contract="not continue-on-error true"):
            self.assertNotRegex(
                gut_step,
                re.compile(r"^        continue-on-error: true$", re.MULTILINE),
            )
        with self.subTest(contract="unconditional"):
            self.assertNotRegex(gut_step, re.compile(r"^        if:", re.MULTILINE))
        gut_position = self.linux_job.find("run: scripts/run_gut_tests.sh")
        if gut_position >= 0:
            for later_step in (
                "Headless physics qualification",
                "Headed acceptance (Xvfb + lavapipe)",
                "Performance harness smoke (Xvfb + lavapipe)",
                "Install Godot export templates",
                "Export Linux release artifact",
            ):
                with self.subTest(later_step=later_step):
                    self.assertLess(gut_position, self.linux_job.index(later_step))

    def test_recovery_shadow_is_non_blocking_and_not_a_platform_dependency(self):
        with self.subTest(contract="recovery shadow job"):
            self.assertIn("  gut-recovery-shadow:\n", self.workflow)
        if "  gut-recovery-shadow:\n" in self.workflow:
            shadow_job = job_body(self.workflow, "gut-recovery-shadow")
            with self.subTest(contract="non-blocking"):
                self.assertRegex(
                    shadow_job,
                    re.compile(r"^    continue-on-error: true$", re.MULTILINE),
                )
            with self.subTest(contract="recovery mode"):
                self.assertIn(
                    "run: scripts/run_gut_tests.sh --recovery-mode", shadow_job
                )
        self.assertNotIn("gut-recovery-shadow", self.linux_job)

    def test_only_ubuntu_jobs_and_checks_are_blocking(self):
        jobs = self.workflow.split("jobs:\n", 1)[1]
        self.assertEqual(
            {"gut-recovery-shadow", "linux"},
            set(re.findall(r"^  ([a-z0-9-]+):$", jobs, re.MULTILINE)),
        )
        self.assertNotRegex(
            self.linux_job, re.compile(r"\b(?:windows|android|macos|ios)\b", re.IGNORECASE)
        )
        audit_step = re.search(
            r"^      - name: Ubuntu release artifact audit unit test\n"
            r"(?:(?!^      - ).)*(?=^      - |\Z)",
            self.linux_job,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(audit_step)
        audit_command = audit_step.group(0)
        audit_class = (
            "tests.test_release_notice_artifacts.UbuntuReleaseArtifactAuditTest"
        )
        self.assertIn("python3 -m unittest " + audit_class, audit_command)
        self.assertEqual(1, audit_command.count(audit_class))
        self.assertNotIn(".test_checker_", audit_command)
        self.assertNotIn("python3 tests/test_release_notice_artifacts.py", audit_command)
        self.assertIn(
            "python3 scripts/check_release_artifacts.py \"$out_zip\"",
            (ROOT / "scripts" / "export_linux_release.sh").read_text(encoding="utf-8"),
        )

    def test_linux_reuses_its_debug_build_for_headed_runtime_gates(self):
        with self.subTest(contract="no standalone headed job"):
            self.assertNotRegex(self.workflow, re.compile(r"^  headed-smoke:$", re.MULTILINE))
        debug_build = "run: scons target=template_debug platform=linux"
        with self.subTest(contract="one Linux debug build"):
            self.assertEqual(1, self.linux_job.count(debug_build))
        debug_build_position = self.linux_job.find(debug_build)
        for step, command in (
            (
                "Headed acceptance (Xvfb + lavapipe)",
                "run: scripts/run_headed_acceptance.sh --xvfb",
            ),
            (
                "Performance harness smoke (Xvfb + lavapipe)",
                "run: xvfb-run -a python3 tests/test_performance_runner.py",
            ),
            (
                "Store headed screenshots locally",
                'cp -a build/headed/. "$AEROSIM_CI_ARTIFACT_RUN_DIR/headed-linux/"',
            ),
        ):
            step_match = re.search(
                rf"^      - name: {re.escape(step)}\n(?:(?!^      - ).)*(?=^      - |\Z)",
                self.linux_job,
                re.MULTILINE | re.DOTALL,
            )
            step_block = step_match.group(0) if step_match else ""
            step_position = step_match.start() if step_match else -1
            with self.subTest(contract="after Linux debug build", step=step):
                self.assertGreater(step_position, debug_build_position)
            with self.subTest(contract="preserved headed command", step=step):
                self.assertIn(command, step_block)

    def test_linux_runtime_evidence_uses_one_recorded_debug_artifact_in_order(self):
        steps = [
            "Build GDExtension",
            "Record Linux debug artifact provenance",
            "GUT GDScript unit tests",
            "Native atomic boundary negative process",
            "Headed acceptance (Xvfb + lavapipe)",
            "Complete-session replay integration",
            "Performance harness smoke (Xvfb + lavapipe)",
            "Headless physics qualification",
        ]
        positions = [self.linux_job.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        provenance_step = re.search(
            r"^      - name: Record Linux debug artifact provenance\n"
            r"(?:(?!^      - ).)*(?=^      - |\Z)",
            self.linux_job,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(provenance_step)
        provenance = provenance_step.group(0) if provenance_step else ""
        for field in ("commit_sha", "gdextension_path", "gdextension_sha256", "native_source_sha256"):
            with self.subTest(field=field):
                self.assertIn(field, provenance)
        for command in (
            "scripts/run_gut_tests.sh",
            "scripts/test_native_atomic_boundary.sh",
            "scripts/run_headed_acceptance.sh --xvfb",
            "scripts/test_replay_integration.sh",
            "scripts/run_headless_smoke.sh",
        ):
            step = re.search(
                rf"^      - name: [^\n]+\n(?:(?!^      - ).)*{re.escape(command)}(?:(?!^      - ).)*(?=^      - |\Z)",
                self.linux_job,
                re.MULTILINE | re.DOTALL,
            )
            with self.subTest(command=command):
                self.assertIsNotNone(step)
                self.assertIn("AEROSIM_NATIVE_PROVENANCE", step.group(0) if step else "")

    def test_runtime_scripts_fail_loudly_without_the_debug_artifact_receipt(self):
        for runner in (
            GUT_RUNNER,
            ATOMIC_BOUNDARY_RUNNER,
            REPLAY_RUNNER,
            HEADLESS_RUNNER,
            HEADED_RUNNER,
            PERFORMANCE_RUNNER,
        ):
            with self.subTest(runner=runner.name, receipt="missing"):
                completed = self._run_direct_runner_with_receipt(runner, None)
                self.assertNotEqual(0, completed.returncode)
                self.assertIn("native artifact provenance is missing", completed.stderr)
            with self.subTest(runner=runner.name, receipt="stale"):
                completed = self._run_direct_runner_with_receipt(
                    runner, {"commit_sha": "0" * 40}
                )
                self.assertNotEqual(0, completed.returncode)
                self.assertIn("native artifact provenance is stale for HEAD", completed.stderr)
        self.assertIn("AEROSIM_NATIVE_PROVENANCE", VERIFY_ISSUE_11.read_text(encoding="utf-8"))

    def test_headed_and_performance_reject_a_receipt_for_an_arbitrary_binary(self):
        for runner in (HEADED_RUNNER, PERFORMANCE_RUNNER):
            with self.subTest(runner=runner.name):
                completed = self._run_direct_runner_with_receipt(
                    runner, {"gdextension_path": "bin/other_debug_extension.so"}
                )
                self.assertNotEqual(0, completed.returncode)
                self.assertIn("fixed debug GDExtension", completed.stderr)

    def test_gpu_effects_gate_reuses_one_recorded_debug_artifact(self):
        workflow = PERFORMANCE_GPU_WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(1, workflow.count("scons target=template_debug platform=linux"))
        self.assertIn("Record Linux debug artifact provenance", workflow)
        gate = re.search(
            r"^      - name: Run full local-Ubuntu G0\.1 gate protocol\n"
            r"(?:(?!^      - ).)*(?=^      - |\Z)",
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(gate)
        self.assertIn("AEROSIM_NATIVE_PROVENANCE", gate.group(0) if gate else "")

    def test_gpu_effects_artifacts_include_a_receipt_bound_manifest(self):
        workflow = PERFORMANCE_GPU_WORKFLOW.read_text(encoding="utf-8")
        manifest = re.search(
            r"^      - name: Write GPU performance artifact manifest\n"
            r"(?:(?!^      - ).)*(?=^      - |\Z)",
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(manifest)
        manifest_step = manifest.group(0) if manifest else ""
        for contract in (
            'Path("build/performance-gpu")',
            'f"effects-{mode}.json"',
            '"manifest.json"',
            "commit_sha",
            "gdextension_sha256",
            "native_source_sha256",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, manifest_step)
        store_step = re.search(
            r"^      - name: Store GPU performance artifacts locally\n"
            r"(?:(?!^      - ).)*(?=^      - |\Z)",
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(store_step)
        self.assertIn("manifest.json", store_step.group(0) if store_step else "")

    def test_known_xbox_path_asserts_signed_angular_response_before_fallback(self):
        source = HEADED_ACCEPTANCE.read_text(encoding="utf-8")
        known_xbox_start = source.index("var known_device_id := await _inject_known_gamepad()")
        fallback_start = source.index("var unknown_device_id := known_device_id + 1")
        for assertion in (
            "omega_x < 0.0",
            "omega_z < 0.0",
            "omega_y < 0.0",
        ):
            with self.subTest(assertion=assertion):
                self.assertIn(assertion, source)
                if assertion in source:
                    index = source.index(assertion)
                    self.assertGreater(index, known_xbox_start)
                    self.assertLess(index, fallback_start)

    def test_ci_keeps_evidence_runner_local_without_hosted_artifact_actions(self):
        self.assertNotRegex(self.workflow, re.compile(r"actions/(upload|download)-artifact@"))
        for step in ("Store headed screenshots locally", "Store Linux replay artifact locally"):
            step_match = re.search(
                rf"^      - name: {re.escape(step)}\n(?:(?!^      - ).)*(?=^      - |\Z)",
                self.linux_job,
                re.MULTILINE | re.DOTALL,
            )
            self.assertIsNotNone(step_match)
            self.assertIn("AEROSIM_CI_ARTIFACT_RUN_DIR", step_match.group(0) if step_match else "")

    def test_headed_runner_retains_logs_and_requires_structured_success(self):
        self._assert_runtime_runner_contract(HEADED_RUNNER, reject_console_errors=True)

    def test_headless_runner_retains_logs_and_requires_structured_completion(self):
        # Headless intentionally exercises HardwareConfig's push_error + fallback path.
        self._assert_runtime_runner_contract(HEADLESS_RUNNER, reject_console_errors=False)

    def test_headless_runner_uses_fixed_240_hz_clock_without_real_time_sync(self):
        completed, _ = self._run_runner(
            HEADLESS_RUNNER,
            "true",
            "Godot Engine fake\n",
            expected_fixed_fps="240",
        )
        self.assertEqual(0, completed.returncode)

    def test_headless_qualification_keeps_core_coverage_and_clock_contract(self):
        step_match = re.search(
            r"^      - name: Headless physics qualification\n"
            r"(?:(?!^      - ).)*(?=^      - |\Z)",
            self.linux_job,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(step_match)
        step = step_match.group(0) if step_match else ""
        for contract in (
            "--seconds 60",
            '["physics_ticks_per_second"])\')" = "240"',
            '["simulated_frames"])\')" = "14400"',
            '["desktop_substeps"])\')" = "60000"',
            '["jolt_collision_trials"])\')" = "800"',
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, step)

    def _assert_runtime_runner_contract(self, runner: Path, reject_console_errors: bool):
        success_scenarios = (
            ("structured true", "Godot Engine fake\n"),
            ("non-prefix ERROR text", "context: ERROR: expected text\n"),
        )
        for scenario, log_text in success_scenarios:
            completed, logs = self._run_runner(runner, "true", log_text)
            with self.subTest(scenario=scenario, contract="zero exit"):
                self.assertEqual(0, completed.returncode)
            with self.subTest(scenario=scenario, contract="retained Godot log"):
                self.assertIn(log_text, logs)

        scenarios = (
            ("structured false", "false", "Godot Engine fake\n"),
            ("structured missing", "missing", "Godot Engine fake\n"),
        )
        if reject_console_errors:
            scenarios += (
                ("Godot error", "true", "ERROR: synthetic failure\n"),
                ("script error", "true", "SCRIPT ERROR: synthetic failure\n"),
            )
        for scenario, result, log_text in scenarios:
            completed, logs = self._run_runner(runner, result, log_text)
            with self.subTest(scenario=scenario, contract="non-zero exit"):
                self.assertNotEqual(0, completed.returncode)
            with self.subTest(scenario=scenario, contract="retained Godot log"):
                self.assertIn(log_text, logs)

        completed, logs = self._run_runner(
            runner, "true", "Godot Engine fake\n", exit_status=7
        )
        with self.subTest(scenario="non-zero process", contract="non-zero exit"):
            self.assertNotEqual(0, completed.returncode)
        with self.subTest(scenario="non-zero process", contract="retained Godot log"):
            self.assertIn("Godot Engine fake\n", logs)

    def _run_runner(
        self,
        runner: Path,
        result: str,
        log_text: str,
        exit_status: int = 0,
        expected_fixed_fps: str | None = None,
        with_native_provenance: bool = True,
    ):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workdir = Path(temporary_directory)
            subprocess.run(["git", "init", "-q"], cwd=workdir, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=workdir, check=True)
            subprocess.run(["git", "config", "user.name", "CI test"], cwd=workdir, check=True)
            (workdir / "seed").write_text("seed\n", encoding="utf-8")
            subprocess.run(["git", "add", "seed"], cwd=workdir, check=True)
            subprocess.run(["git", "commit", "-qm", "seed"], cwd=workdir, check=True)
            fake_godot = workdir / "fake_godot.py"
            fake_godot.write_text(FAKE_GODOT, encoding="utf-8")
            fake_godot.chmod(0o755)
            if with_native_provenance:
                extension = workdir / "bin" / "libaerosim_native.linux.template_debug.x86_64.so"
                extension.parent.mkdir(parents=True)
                extension.write_bytes(b"fake native extension\n")
                receipt = workdir / "build" / "native_debug_artifact.json"
                receipt.parent.mkdir(parents=True)
                receipt.write_text(
                    json.dumps(
                        {
                            "commit_sha": subprocess.check_output(
                                ["git", "rev-parse", "HEAD"], cwd=workdir, text=True
                            ).strip(),
                            "gdextension_path": str(extension.relative_to(workdir)),
                            "gdextension_sha256": hashlib.sha256(extension.read_bytes()).hexdigest(),
                            "native_source_sha256": hashlib.sha256(b"").hexdigest(),
                        }
                    ),
                    encoding="utf-8",
                )
            environment = os.environ.copy()
            environment.update(
                GODOT_BIN=str(fake_godot),
                FAKE_GODOT_RESULT=result,
                FAKE_GODOT_LOG=log_text,
                FAKE_GODOT_EXIT=str(exit_status),
            )
            if expected_fixed_fps is not None:
                environment["FAKE_GODOT_EXPECT_FIXED_FPS"] = expected_fixed_fps
            completed = subprocess.run(
                [str(runner)],
                cwd=workdir,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            logs = [path.read_text(encoding="utf-8") for path in workdir.rglob("*.log")]
            return completed, logs

    def _run_direct_runner_with_receipt(
        self, runner: Path, receipt_overrides: dict[str, str] | None
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            workdir = Path(temporary_directory)
            subprocess.run(["git", "init", "-q"], cwd=workdir, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=workdir, check=True)
            subprocess.run(["git", "config", "user.name", "CI test"], cwd=workdir, check=True)
            (workdir / "seed").write_text("seed\n", encoding="utf-8")
            subprocess.run(["git", "add", "seed"], cwd=workdir, check=True)
            subprocess.run(["git", "commit", "-qm", "seed"], cwd=workdir, check=True)
            fake_godot = workdir / "fake_godot.py"
            fake_godot.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            fake_godot.chmod(0o755)
            extension = workdir / "bin" / "libaerosim_native.linux.template_debug.x86_64.so"
            extension.parent.mkdir(parents=True)
            extension.write_bytes(b"fake native extension\n")
            if receipt_overrides is not None:
                receipt = workdir / "build" / "native_debug_artifact.json"
                receipt.parent.mkdir(parents=True)
                receipt_data = {
                    "commit_sha": subprocess.check_output(
                        ["git", "rev-parse", "HEAD"], cwd=workdir, text=True
                    ).strip(),
                    "gdextension_path": str(extension.relative_to(workdir)),
                    "gdextension_sha256": hashlib.sha256(extension.read_bytes()).hexdigest(),
                    "native_source_sha256": hashlib.sha256(b"").hexdigest(),
                }
                receipt_data.update(receipt_overrides)
                if receipt_data["gdextension_path"] != str(extension.relative_to(workdir)):
                    other_extension = workdir / receipt_data["gdextension_path"]
                    other_extension.parent.mkdir(parents=True, exist_ok=True)
                    other_extension.write_bytes(b"other native extension\n")
                    receipt_data["gdextension_sha256"] = hashlib.sha256(other_extension.read_bytes()).hexdigest()
                receipt.write_text(json.dumps(receipt_data), encoding="utf-8")
            environment = os.environ.copy()
            environment.update(GODOT_BIN=str(fake_godot), DISPLAY=":99")
            command = [str(runner)]
            if runner == PERFORMANCE_RUNNER:
                godot_cpp_dir = workdir / "godot-cpp"
                (godot_cpp_dir / ".git").mkdir(parents=True)
                (godot_cpp_dir / "SConstruct").write_text("", encoding="utf-8")
                environment["GODOT_CPP_DIR"] = str(godot_cpp_dir)
                command.extend(("--mode", "smoke", "--warmup-seconds", "0", "--seconds", "0.1"))
            return subprocess.run(
                command,
                cwd=workdir,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )


if __name__ == "__main__":
    unittest.main()
