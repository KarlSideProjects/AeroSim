import os
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "scripts/test_px4_sitl_launcher.sh"
PX4_REVISION = "1dacb4cdef2d7145754fc788fa8dc482eed74b40"


class Px4SitlLauncherTests(unittest.TestCase):
    def test_wind_step_qualification_check_mode_accepts_valid_authentic_evidence(self):
        evidence = {
            "kind": "aerosim.px4_wind_step_qualification", "px4_revision": PX4_REVISION,
            "transport": "real", "authority": "px4_exclusive",
            "wind": {"applied_tick": 1, "replay_event_tick": 1, "replay_identity": "wind-step"},
            "actuators": {"fresh": True, "mapping_verified": True, "age_seconds": 0.01},
            "lean": {"observed": True, "max_abs_roll_or_pitch_rad": 0.1},
            "position_error_m": [0.1], "limits": {"rms_m": 0.3, "max_m": 0.4},
        }
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = Path(directory) / "evidence.json"
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            result = subprocess.run(
                [str(LAUNCHER), "--wind-step-qualification"],
                cwd=ROOT,
                env=os.environ | {"PX4_SOURCE_DIR": str(Path(directory) / "missing-px4"), "AEROSIM_PX4_WIND_STEP_EVIDENCE": str(evidence_path)},
                text=True, capture_output=True, check=False,
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"mode":"check"', result.stdout)

    def test_wind_step_qualification_creates_its_output_directory(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('mkdir -p "$(dirname "$qualification_log")"', source)

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
