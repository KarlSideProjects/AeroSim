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
                r"^  group: ci-\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}\n"
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
                r"(?P<gut_step>^      - name: .*GUT.*\n"
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
        with self.subTest(contract="not continue-on-error"):
            self.assertNotIn("continue-on-error:", gut_step)
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
        for job in ("linux", "windows", "android"):
            with self.subTest(contract="not a platform dependency", job=job):
                self.assertNotIn("gut-recovery-shadow", job_body(self.workflow, job))

    def test_linux_reuses_its_debug_build_for_headed_runtime_gates(self):
        with self.subTest(contract="no standalone headed job"):
            self.assertNotRegex(self.workflow, re.compile(r"^  headed-smoke:$", re.MULTILINE))
        debug_build = "run: scons target=template_debug platform=linux"
        with self.subTest(contract="one Linux debug build"):
            self.assertEqual(1, self.linux_job.count(debug_build))
        debug_build_position = self.linux_job.find(debug_build)
        for step in (
            "Headed acceptance (Xvfb + lavapipe)",
            "Performance harness smoke (Xvfb + lavapipe)",
            "Store headed screenshots locally",
        ):
            with self.subTest(contract="after Linux debug build", step=step):
                self.assertGreater(self.linux_job.find(step), debug_build_position)
        for command in (
            "run: scripts/run_headed_acceptance.sh --xvfb",
            "run: xvfb-run -a python3 tests/test_performance_runner.py",
            'cp -a build/headed/. "$AEROSIM_CI_ARTIFACT_RUN_DIR/headed-linux/"',
        ):
            with self.subTest(contract="preserved headed command", command=command):
                self.assertIn(command, self.linux_job)

    def test_headed_runner_retains_logs_and_requires_structured_success(self):
        self._assert_runtime_runner_contract(HEADED_RUNNER)

    def test_headless_runner_retains_logs_and_requires_structured_completion(self):
        self._assert_runtime_runner_contract(HEADLESS_RUNNER)

    def _assert_runtime_runner_contract(self, runner: Path):
        success_scenarios = (
            ("structured true", "Godot Engine fake\n"),
            ("non-prefix ERROR text", "context: ERROR: expected text\n"),
        )
        for scenario, log_text in success_scenarios:
            completed, _logs = self._run_runner(runner, "true", log_text)
            with self.subTest(scenario=scenario, contract="zero exit"):
                self.assertEqual(0, completed.returncode)

        scenarios = (
            ("structured false", "false", "Godot Engine fake\n"),
            ("structured missing", "missing", "Godot Engine fake\n"),
            ("Godot error", "true", "ERROR: synthetic failure\n"),
            ("script error", "true", "SCRIPT ERROR: synthetic failure\n"),
        )
        for scenario, result, log_text in scenarios:
            completed, logs = self._run_runner(runner, result, log_text)
            with self.subTest(scenario=scenario, contract="non-zero exit"):
                self.assertNotEqual(0, completed.returncode)
            with self.subTest(scenario=scenario, contract="retained Godot log"):
                self.assertIn(log_text, logs)

    def _run_runner(self, runner: Path, result: str, log_text: str):
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
