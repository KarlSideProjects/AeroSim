import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "terrain_3d"
RELEASE_SHA256 = "a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2"
VERSION = f"v1.0.2-stable (sha256:{RELEASE_SHA256})"


class Terrain3DDependencyTest(unittest.TestCase):
    def test_pinned_linux_plugin_is_enabled_and_attributed(self) -> None:
        descriptor = ADDON / "terrain.gdextension"
        self.assertTrue(descriptor.is_file())
        self.assertTrue((ADDON / "bin" / "libterrain.linux.release.x86_64.so").is_file())
        self.assertIn("enabled=PackedStringArray(\"res://addons/terrain_3d/plugin.cfg\")", (ROOT / "project.godot").read_text())
        self.assertIn("libterrain.linux.release.x86_64.so", descriptor.read_text())
        manifest = json.loads((ROOT / "third_party" / "licenses.json").read_text())
        entry = next(item for item in manifest["dependencies"] if item["name"] == "Terrain3D")
        self.assertEqual(entry["license"], "MIT")
        self.assertEqual(entry["version"], VERSION)
        self.assertEqual(entry["homepage"], "https://github.com/TokisanGames/Terrain3D")
        self.assertIn(RELEASE_SHA256, (ROOT / "assets" / "third_party" / "terrain3d" / "asset_notes.md").read_text())

    def test_license_gate_rejects_missing_terrain3d_attribution(self) -> None:
        manifest = json.loads((ROOT / "third_party" / "licenses.json").read_text())
        manifest["dependencies"] = [entry for entry in manifest["dependencies"] if entry["name"] != "Terrain3D"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "licenses.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "scripts/check_licenses.py", "--manifest", str(path)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required attribution missing: Terrain3D", result.stderr)


if __name__ == "__main__":
    unittest.main()
