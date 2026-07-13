#!/usr/bin/env python3
"""Intent: CI fails fast once per PR without weakening runtime evidence."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
HEADED_RUNNER = ROOT / "scripts" / "run_headed_acceptance.sh"
HEADLESS_RUNNER = ROOT / "scripts" / "run_headless_smoke.sh"


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
                r"^  group: .*\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}\n"
                r"^  cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}$",
                re.MULTILINE,
            ),
        )

    def test_blocking_gut_runs_immediately_after_linux_debug_build(self):
        self.assertRegex(
            self.linux_job,
            re.compile(
                r"^      - name: Build GDExtension\n"
                r"^        run: scons target=template_debug platform=linux\n"
                r"\n"
                r"^      - name: .*GUT.*\n"
                r"^        run: scripts/run_gut_tests\.sh$",
                re.MULTILINE,
            ),
        )
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
                self.assertNotRegex(
                    job_body(self.workflow, job),
                    re.compile(r"^    needs:", re.MULTILINE),
                )

    def test_linux_reuses_its_debug_build_for_headed_runtime_gates(self):
        with self.subTest(contract="no standalone headed job"):
            self.assertNotRegex(self.workflow, re.compile(r"^  headed-smoke:$", re.MULTILINE))
        for step in (
            "Headed acceptance (Xvfb + lavapipe)",
            "Performance harness smoke (Xvfb + lavapipe)",
            "Store headed screenshots locally",
        ):
            with self.subTest(step=step):
                self.assertIn(step, self.linux_job)
        if "Headed acceptance (Xvfb + lavapipe)" in self.linux_job:
            self.assertLess(
                self.linux_job.index("Build GDExtension"),
                self.linux_job.index("Headed acceptance (Xvfb + lavapipe)"),
            )

    def test_headed_runner_retains_logs_and_requires_structured_success(self):
        runner = HEADED_RUNNER.read_text(encoding="utf-8")
        self._assert_runtime_runner_contract(runner, "passed")

    def test_headless_runner_retains_logs_and_requires_structured_completion(self):
        runner = HEADLESS_RUNNER.read_text(encoding="utf-8")
        self._assert_runtime_runner_contract(runner, "completed")

    def _assert_runtime_runner_contract(self, runner: str, result_key: str):
        with self.subTest(contract="retained Godot log"):
            self.assertIn("--log-file", runner)
        with self.subTest(contract=f"structured {result_key} result"):
            self.assertIn("json.load", runner)
            self.assertRegex(
                runner,
                re.compile(rf"(?:\[['\"]{result_key}['\"]\]|\.get\(['\"]{result_key}['\"]\))"),
            )
        with self.subTest(contract="stable Godot error-prefix gate"):
            self.assertIn("ERROR:", runner)
            self.assertIn("SCRIPT ERROR:", runner)


if __name__ == "__main__":
    unittest.main()
