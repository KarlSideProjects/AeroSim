import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GodotSetupTest(unittest.TestCase):
    def test_version_floor_and_matching_templates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "local godot"
            source = root / "templates"
            source.mkdir()
            for name in ("linux_debug.x86_64", "linux_release.x86_64"):
                (source / name).write_bytes(b"local template")
            env = dict(os.environ, GODOT_BIN=str(binary),
                       AEROSIM_TOOL_ROOT=str(root), GITHUB_ENV=str(root / "env"),
                       XDG_DATA_HOME=str(root / "data"),
                       GODOT_EXPORT_TEMPLATES_DIR=str(source))

            def run(version, mode):
                binary.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n")
                binary.chmod(0o755)
                return subprocess.run(["scripts/setup_godot.sh", mode], cwd=ROOT,
                                      env=env, capture_output=True, text=True)

            for version in ("4.7.stable.official.hash", "4.7.2.stable.official.hash",
                            "4.8.stable.official.hash", "5.0.stable.official.hash"):
                with self.subTest(version=version):
                    result = run(version, "editor")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"GODOT_BIN={binary}\n", (root / "env").read_text())
            for version in ("4.6.9.stable.official.hash", "3.7.stable.official.hash",
                            "4.7.beta1.official.hash", "unexpected version"):
                with self.subTest(version=version):
                    self.assertNotEqual(run(version, "editor").returncode, 0)

            (source / "version.txt").write_text("4.7.stable\n")
            result = run("4.7.2.stable.official.hash", "templates")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("do not match", result.stderr)
            (source / "version.txt").write_text("4.7.2.stable\n")
            result = run("4.7.2.stable.official.hash", "templates")
            self.assertEqual(result.returncode, 0, result.stderr)
            destination = root / "data/godot/export_templates/4.7.2.stable"
            self.assertEqual((destination / "linux_release.x86_64").read_bytes(),
                             b"local template")
            self.assertEqual((source / "version.txt").read_text(), "4.7.2.stable\n")


if __name__ == "__main__":
    unittest.main()
