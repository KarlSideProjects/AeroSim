#!/usr/bin/env python3
"""Intent: Formula-port attribution cannot drift from the pinned oracle contract."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LICENSE_SCAN = ROOT / "scripts" / "check_licenses.py"
MANIFEST = ROOT / "third_party" / "licenses.json"
CONTRACT = ROOT / "oracles" / "gym_pybullet_drones_contract.json"
NAME = "gym-pybullet-drones"
SCOPE = (
    "Applies only to AeroSim source-code/formula ports derived from "
    "gym-pybullet-drones; it does not claim redistribution rights for upstream "
    "papers/PDFs, experimental datasets, or constants/parameter tables."
)
MIT_NOTICE = """MIT License

Copyright (c) 2020 Jacopo Panerati

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the \"Software\"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


class GymPyBulletDronesNoticeTest(unittest.TestCase):
    def gym_dependency(self):
        contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
        return {
            "name": NAME,
            "version": contract["commit"],
            "license": "MIT",
            "homepage": contract["repository_url"],
            "attribution_scope": SCOPE,
            "notice": MIT_NOTICE,
        }

    def run_scan(self, dependencies, notice_out=None):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "licenses.json"
            manifest.write_text(json.dumps({"dependencies": dependencies}), encoding="utf-8")
            command = [
                sys.executable,
                str(LICENSE_SCAN),
                "--manifest",
                str(manifest),
                "--allow-missing-terrain3d-attribution",
            ]
            if notice_out:
                command.extend(["--notice-out", str(notice_out)])
            return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)

    def test_manifest_entry_matches_contract_and_complete_mit_notice(self):
        dependencies = json.loads(MANIFEST.read_text(encoding="utf-8"))["dependencies"]
        entry = next(dependency for dependency in dependencies if dependency["name"] == NAME)
        contract = json.loads(CONTRACT.read_text(encoding="utf-8"))

        self.assertEqual(entry["license"], "MIT")
        self.assertEqual(entry["homepage"], contract["repository_url"])
        self.assertEqual(entry["version"], contract["commit"])
        self.assertEqual(entry["attribution_scope"], SCOPE)
        self.assertEqual(entry["notice"], MIT_NOTICE)

    def test_scan_rejects_a_missing_required_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            notice_out = Path(directory) / "THIRD_PARTY_NOTICES.txt"
            result = self.run_scan([], notice_out)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required attribution missing: gym-pybullet-drones", result.stderr)
            self.assertFalse(notice_out.exists())

    def test_scan_rejects_scope_or_contract_drift(self):
        invalid_dependencies = []
        for field, invalid_value in (
            ("attribution_scope", None),
            ("homepage", "https://github.com/utiasDSL/gym-pybullet-drones"),
            ("version", "0000000000000000000000000000000000000000"),
        ):
            dependency = self.gym_dependency()
            dependency[field] = invalid_value
            invalid_dependencies.append((field, dependency))

        for field, dependency in invalid_dependencies:
            with self.subTest(field=field):
                result = self.run_scan([dependency])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("gym-pybullet-drones attribution invalid", result.stderr)

    def test_scan_rejects_a_truncated_mit_notice(self):
        dependency = self.gym_dependency()
        dependency["notice"] = MIT_NOTICE.removesuffix(
            "\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
            "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
            "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
            "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
            "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
            "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n"
            "SOFTWARE."
        )

        result = self.run_scan([dependency])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gym-pybullet-drones attribution invalid", result.stderr)

    def test_generated_notice_includes_scope_and_complete_mit_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            notice_out = Path(directory) / "THIRD_PARTY_NOTICES.txt"
            result = self.run_scan([self.gym_dependency()], notice_out)

            self.assertEqual(result.returncode, 0, result.stderr)
            notice = notice_out.read_text(encoding="utf-8")

        self.assertIn(f"Attribution scope: {SCOPE}", notice)
        self.assertIn(MIT_NOTICE, notice)


if __name__ == "__main__":
    unittest.main()
