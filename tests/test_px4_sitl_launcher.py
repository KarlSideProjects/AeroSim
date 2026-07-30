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

    def test_runtime_disables_the_interactive_px4_shell(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('"$px4_binary" -d -i 0', source)

    def test_generated_hil_runtime_uses_hil_pwm_outputs_without_changing_preflight(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn("-e 's/pwm_out_sim start -m sim/pwm_out_sim start -m hil/'", source)
        self.assertIn("rg -q 'pwm_out_sim start -m hil'", source)
        self.assertIn("commander start -h", source)
        self.assertNotIn("COM_DISARM_PRFLT", source)

    def test_wind_qualification_runs_the_real_gsp_controller_and_two_vehicle_settings(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('config/sitl/px4_iris_wind_qualification.json', source)
        self.assertIn('res://tests/headless/px4_wind_step_qualification.gd', source)
        self.assertIn('scripts/px4_wind_step_mission.py', source)
        self.assertIn('runtime_ready_file="$gsp_ready_file"', source)

    def test_wind_qualification_cleanup_has_a_fixed_trace_publish_deadline(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('touch "$stop_file"', source)
        self.assertIn('for _attempt in $(seq 1 50)', source)
        self.assertIn('sleep 0.1', source)

    def test_wind_run_clears_only_its_explicit_artifacts_and_fails_closed_on_stale_output(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('wind_artifacts=(', source)
        self.assertIn('rm -f "${wind_artifacts[@]}"', source)
        self.assertIn('"$log_dir/wind_step_evidence.json"', source)
        self.assertIn('"$log_dir/wind_step_qualification.json"', source)
        self.assertIn('"$log_dir/wind_step_bridge_trace.json.tmp"', source)
        self.assertIn('touch "$run_marker"', source)
        self.assertIn('[ ! "$artifact" -nt "$run_marker" ]', source)
        self.assertIn('grep -Eq \'^(SCRIPT ERROR:|ERROR:)\' "$godot_log"', source)

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
