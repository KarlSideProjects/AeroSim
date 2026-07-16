#!/usr/bin/env python3
"""Intent: the shipped license server dependency closure stays pinned and attributable."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "check_license_dependencies.py"
LOCK = ROOT / "license_server" / "requirements.lock"
MANIFEST = ROOT / "third_party" / "licenses.json"
EXPECTED_INSTALLED = [
    {"name": "PyJWT", "version": "2.13.0"},
    {"name": "cryptography", "version": "49.0.0"},
    {"name": "cffi", "version": "2.0.0"},
    {"name": "pycparser", "version": "3.0"},
]


class LicenseDependencyContractTest(unittest.TestCase):
    def run_checker(self, lock: Path, installed: list[dict]):
        with tempfile.TemporaryDirectory() as directory:
            installed_path = Path(directory) / "installed.json"
            installed_path.write_text(json.dumps(installed), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--lock",
                    str(lock),
                    "--manifest",
                    str(MANIFEST),
                    "--installed-json",
                    str(installed_path),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_repo_lock_matches_the_complete_attributed_runtime_closure(self):
        result = self.run_checker(LOCK, EXPECTED_INSTALLED)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("license runtime closure passed: 4 dependencies", result.stdout)

    def test_cffi_2_1_fixture_is_rejected_instead_of_widening_the_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "requirements.lock"
            lock.write_text(
                LOCK.read_text(encoding="utf-8").replace("cffi==2.0.0", "cffi==2.1.0"),
                encoding="utf-8",
            )
            result = self.run_checker(lock, EXPECTED_INSTALLED)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cffi must be exactly 2.0.0", result.stderr)

    def test_unlocked_installed_package_fails_closed(self):
        installed = [*EXPECTED_INSTALLED, {"name": "requests", "version": "2.32.5"}]

        result = self.run_checker(LOCK, installed)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed runtime closure differs from lock", result.stderr)


if __name__ == "__main__":
    unittest.main()
