#!/usr/bin/env python3
"""Intent: Tier 1 release archives carry the generated third-party notice."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_CHECK = ROOT / "scripts" / "check_release_artifacts.py"
LICENSE_SCAN = ROOT / "scripts" / "check_licenses.py"
MANIFEST = ROOT / "third_party" / "licenses.json"


class ReleaseNoticeArtifactsTest(unittest.TestCase):
    def generated_notice(self, directory: Path) -> str:
        notice_path = directory / "THIRD_PARTY_NOTICES.txt"
        result = subprocess.run(
            [sys.executable, str(LICENSE_SCAN), "--notice-out", str(notice_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return notice_path.read_text(encoding="utf-8")

    def write_archive(self, path: Path, notice_path: str | None, notice: str = ""):
        with ZipFile(path, "w", ZIP_DEFLATED) as archive:
            archive.writestr("payload.bin", "release payload")
            if notice_path:
                archive.writestr(notice_path, notice)

    def check(self, artifact: Path):
        return subprocess.run(
            [sys.executable, str(ARTIFACT_CHECK), str(artifact)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_checker_rejects_archive_without_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_archive(artifact, None)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing THIRD_PARTY_NOTICES.txt", result.stderr)

    def test_checker_rejects_production_android_archive_without_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-android-production.apk"
            self.write_archive(artifact, None)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing THIRD_PARTY_NOTICES.txt", result.stderr)

    def test_checker_rejects_truncated_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-windows.zip"
            self.write_archive(
                artifact,
                "AeroSim-windows/THIRD_PARTY_NOTICES.txt",
                "gym-pybullet-drones\nCopyright (c) 2020 Jacopo Panerati\n",
            )
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("THIRD_PARTY_NOTICES.txt missing required text", result.stderr)

    def test_checker_rejects_notice_missing_mit_warranty(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entry = next(item for item in manifest["dependencies"] if item["name"] == "gym-pybullet-drones")
        truncated_notice = "\n".join((
            "gym-pybullet-drones",
            f"Attribution scope: {entry['attribution_scope']}",
            entry["notice"].split("\n\nTHE SOFTWARE IS PROVIDED", 1)[0],
        ))
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_archive(artifact, "AeroSim-linux/THIRD_PARTY_NOTICES.txt", truncated_notice)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("THIRD_PARTY_NOTICES.txt missing required text", result.stderr)

    def assert_checker_accepts_notice_path(self, filename: str, notice_path: str):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / filename
            self.write_archive(artifact, notice_path, notice)
            result = self.check(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_accepts_linux_notice_path(self):
        self.assert_checker_accepts_notice_path(
            "AeroSim-linux.zip", "AeroSim-linux/THIRD_PARTY_NOTICES.txt"
        )

    def test_checker_accepts_deferred_windows_and_android_notice_paths(self):
        archive_paths = {
            "AeroSim-windows.zip": "AeroSim-windows/THIRD_PARTY_NOTICES.txt",
            "AeroSim-android.apk": "assets/THIRD_PARTY_NOTICES.txt",
        }
        for filename, notice_path in archive_paths.items():
            with self.subTest(artifact=filename):
                self.assert_checker_accepts_notice_path(filename, notice_path)


if __name__ == "__main__":
    unittest.main()
