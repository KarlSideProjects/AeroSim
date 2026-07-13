#!/usr/bin/env python3
"""Intent: concurrent Android CI jobs must not share an emulator lifecycle."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class AndroidCiIsolationTest(unittest.TestCase):
    def test_android_job_serializes_emulator_access_without_port_hashing(self):
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        android_job = workflow.split("  android:\n", 1)[1].split("  headed-smoke:\n", 1)[0]

        self.assertRegex(
            android_job,
            re.compile(
                r"^    concurrency:\n"
                r"^      group: aerosim-android-emulator\n"
                r"^      cancel-in-progress: false\n"
                r"^    runs-on:",
                re.MULTILINE,
            ),
        )
        self.assertNotIn("GITHUB_RUN_ID % 16", android_job)
        self.assertNotIn("emulator-port:", android_job)


if __name__ == "__main__":
    unittest.main()
