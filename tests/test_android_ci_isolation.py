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

    def test_linux_job_runs_delivery_drill(self):
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        linux_job = workflow.split("  linux:\n", 1)[1].split("  windows:\n", 1)[0]

        self.assertIn("run: scripts/test_delivery_drill.sh", linux_job)

    def test_production_keystore_cleanup_is_armed_before_decode(self):
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        production_step = workflow.split(
            "      - name: Export production-signed Android release artifact\n", 1
        )[1].split(
            "      - name: Store production-signed Android release artifact locally\n", 1
        )[0]

        self.assertLess(
            production_step.index("trap 'rm -f \"$release_keystore\"' EXIT"),
            production_step.index("base64 --decode"),
        )

    def test_production_export_supplies_java_home_and_fingerprint(self):
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        production_step = workflow.split(
            "      - name: Export production-signed Android release artifact\n", 1
        )[1].split(
            "      - name: Store production-signed Android release artifact locally\n", 1
        )[0]

        self.assertIn('JAVA_HOME="$java_home"', production_step)
        self.assertIn('ANDROID_RELEASE_CERT_SHA256', production_step)
        self.assertIn(
            'Missing Android production certificate fingerprint variable',
            production_step,
        )


if __name__ == "__main__":
    unittest.main()
