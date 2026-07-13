#!/usr/bin/env python3
"""Intent: CI fails fast once per PR without weakening runtime evidence."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
HEADED_RUNNER = ROOT / "scripts" / "run_headed_acceptance.sh"
HEADLESS_RUNNER = ROOT / "scripts" / "run_headless_smoke.sh"

FAKE_GODOT = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]

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
    ):
        (result_path.parent / screenshot).write_bytes(b"fake png")
else:
    result_path = Path(runner_args[runner_args.index("--output") + 1])
    csv_path = Path(runner_args[runner_args.index("--csv-output") + 1])
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.write_text("time_s\\n0\\n", encoding="utf-8")
    result_key = "completed"

mode = os.environ["FAKE_GODOT_RESULT"]
result = {} if mode == "missing" else {result_key: mode == "true"}
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

    def test_blocking_gut_runs_immediately_after_linux_debug_build(self):
        match = re.search(
            re.compile(
                r"^      - name: Build GDExtension\n"
                r"^        run: scons target=template_debug platform=linux\n"
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
                "Headless smoke",
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
        for method in (
            "test_checker_rejects_archive_without_notice",
            "test_checker_rejects_notice_missing_mit_warranty",
            "test_checker_accepts_linux_notice_path",
            "test_checker_rejects_extra_linux_entry_to_keep_python_out_of_release",
            "test_checker_rejects_missing_linux_native_entry_instead_of_partial_scan",
            "test_checker_rejects_duplicate_linux_entry_because_shape_must_be_unambiguous",
            "test_checker_rejects_non_elf_native_payloads_before_runtime_scan",
            "test_checker_rejects_truncated_linux_zip_without_a_traceback",
            "test_checker_rejects_crc_corruption_in_native_payload",
            "test_checker_rejects_encrypted_native_payload_without_password_fallback",
            "test_checker_rejects_encrypted_notice_without_password_fallback",
            "test_checker_rejects_unreadable_native_payload_without_skipping_it",
            "test_checker_rejects_unreadable_notice_without_skipping_it",
            "test_checker_rejects_libpython_sonames_in_native_payloads",
            "test_checker_rejects_cpython_lifecycle_and_execution_evidence",
            "test_checker_rejects_oracle_cache_path_in_native_payload",
            "test_checker_rejects_complete_base_aviary_source_across_native_payloads",
            "test_checker_accepts_isolated_cpython_markers_and_boundary_lookalikes",
            "test_checker_accepts_partial_base_aviary_source_evidence",
            "test_checker_accepts_python_names_in_notice_and_native_provenance",
        ):
            self.assertIn(
                "tests.test_release_notice_artifacts.ReleaseNoticeArtifactsTest." + method,
                audit_command,
            )
        self.assertIn("python3 -m unittest", audit_command)
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

    def test_headed_runner_retains_logs_and_requires_structured_success(self):
        self._assert_runtime_runner_contract(HEADED_RUNNER, reject_console_errors=True)

    def test_headless_runner_retains_logs_and_requires_structured_completion(self):
        # Headless intentionally exercises HardwareConfig's push_error + fallback path.
        self._assert_runtime_runner_contract(HEADLESS_RUNNER, reject_console_errors=False)

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

    def _run_runner(self, runner: Path, result: str, log_text: str, exit_status: int = 0):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workdir = Path(temporary_directory)
            fake_godot = workdir / "fake_godot.py"
            fake_godot.write_text(FAKE_GODOT, encoding="utf-8")
            fake_godot.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                GODOT_BIN=str(fake_godot),
                FAKE_GODOT_RESULT=result,
                FAKE_GODOT_LOG=log_text,
                FAKE_GODOT_EXIT=str(exit_status),
            )
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


if __name__ == "__main__":
    unittest.main()
