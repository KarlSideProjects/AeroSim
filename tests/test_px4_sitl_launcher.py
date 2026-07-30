import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "scripts/test_px4_sitl_launcher.sh"


class Px4SitlLauncherTests(unittest.TestCase):
    def test_wind_step_qualification_does_not_pass_without_authentic_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ | {
                "PX4_SOURCE_DIR": str(Path(directory) / "missing-px4"),
                "AEROSIM_PX4_WIND_STEP_EVIDENCE": "",
            }
            result = subprocess.run(
                [str(LAUNCHER), "--wind-step-qualification"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PX4 wind-step qualification unavailable or failed", result.stderr)
