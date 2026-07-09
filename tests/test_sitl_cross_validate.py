import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TOOL = REPO_ROOT / "scripts" / "sitl_cross_validate.py"


class SitlCrossValidationToolTest(unittest.TestCase):
    def test_missing_adapter_fails_loud_before_claiming_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    "--report",
                    str(report),
                    "--build-dir",
                    str(Path(tmp) / "build"),
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing Betaflight SITL adapter", result.stderr)
            self.assertIn("not verified", result.stderr)
            self.assertFalse(report.exists())

    def test_external_adapter_report_proves_threshold_and_gpl_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            adapter = Path(tmp) / "adapter.py"
            adapter.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import csv
                    import sys

                    reader = csv.DictReader(sys.stdin)
                    writer = csv.DictWriter(
                        sys.stdout,
                        fieldnames=["time_s", "roll_degrees", "pitch_degrees", "yaw_degrees"],
                    )
                    writer.writeheader()
                    yaw = 0.0
                    previous_time = None
                    for row in reader:
                        time_s = float(row["time_s"])
                        if previous_time is not None:
                            yaw += float(row["yaw_rate_degrees_per_second"]) * (time_s - previous_time)
                        previous_time = time_s
                        writer.writerow({
                            "time_s": f"{time_s:.9f}",
                            "roll_degrees": row["roll_degrees"],
                            "pitch_degrees": row["pitch_degrees"],
                            "yaw_degrees": f"{yaw:.9f}",
                        })
                    """
                ),
                encoding="utf-8",
            )
            adapter.chmod(0o755)
            report = Path(tmp) / "report.json"

            subprocess.run(
                [
                    sys.executable,
                    str(TOOL),
                    "--adapter",
                    str(adapter),
                    "--report",
                    str(report),
                    "--build-dir",
                    str(Path(tmp) / "build"),
                ],
                cwd=REPO_ROOT,
                check=True,
                text=True,
            )

            data = json.loads(report.read_text(encoding="utf-8"))

        self.assertGreaterEqual(data["minimum_correlation"], 0.85)
        self.assertFalse(data["tier1_release_artifact"])
        self.assertEqual(data["gpl_isolation"]["adapter_boundary"], "external_process_stdio")
        self.assertEqual(data["verdict"], "passed")


if __name__ == "__main__":
    unittest.main()
