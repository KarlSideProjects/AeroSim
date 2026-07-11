#!/usr/bin/env python3
"""Intent: G0.6a replay diagnostics identify the first divergent physics frame."""

import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


class CompareReplayArtifactsTest(unittest.TestCase):
    def test_reports_first_checkpoint_that_exceeds_g06a_tolerance(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "compare_replay_artifacts.py"),
                str(FIXTURES / "replay_checkpoint_reference.json"),
                str(FIXTURES / "replay_checkpoint_divergent.json"),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("frame=7", completed.stderr)
        self.assertIn("position=0.060000000 m", completed.stderr)


if __name__ == "__main__":
    unittest.main()
