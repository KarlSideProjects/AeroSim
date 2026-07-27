import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class GspIssue251ContractTests(unittest.TestCase):
    def test_gpu_neutral_paired_runner_contract(self) -> None:
        runner = (ROOT / "scripts" / "run_gsp_idle_benchmark.sh").read_text(encoding="utf-8")
        self.assertIn("--warmup-seconds 10", runner)
        self.assertIn("--seconds 60", runner)
        self.assertIn("authenticated-idle", runner)
        self.assertIn("comparison.json", runner)
        self.assertNotIn("NVIDIA", runner)
        self.assertNotIn("--require-adapter", runner)

    def test_release_report_is_in_reports_directory(self) -> None:
        self.assertTrue((ROOT / "docs" / "reports" / "task-11-report.md").is_file())
        self.assertFalse((ROOT / "task-11-report.md").exists())
