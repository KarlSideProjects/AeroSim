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
AMBIENT_CG = "ambientCG Ground037 and Rock023"
AMBIENT_CG_TEXTURE_HASHES = {
    "ground037_alb_ht.png": "dd93b05e107b15ebd3b94075cb31068a12e490a1fa5e58df3c9cbd54dc33e492",
    "ground037_nrm_rgh.png": "02608f96e151ad203724bbc16c5f8df657818c63cb5782725b1bcfe307073975",
    "rock023_alb_ht.png": "ad598379cd27e113e78c869b743a77f8d8b442824dbf3fc43dcc03925bb91832",
    "rock023_nrm_rgh.png": "a54a3cbbcb3ad4313fad8afea5e98de972cd8e03e28238b7671bda2e24570b3e",
}


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
        material_entry = next(item for item in manifest["dependencies"] if item["name"] == AMBIENT_CG)
        self.assertEqual(material_entry["license"], "CC0-1.0")
        self.assertEqual(material_entry["homepage"], "https://ambientcg.com/")
        self.assertIn("Terrain Range grass, soil/sand, and rock", material_entry["attribution_scope"])
        texture_dir = ROOT / "assets" / "third_party" / "terrain3d_demo" / "demo" / "assets" / "textures"
        for file_name, expected_hash in AMBIENT_CG_TEXTURE_HASHES.items():
            self.assertEqual(hashlib.sha256((texture_dir / file_name).read_bytes()).hexdigest(), expected_hash)

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

    def test_license_gate_rejects_missing_ambientcg_attribution(self) -> None:
        manifest = json.loads((ROOT / "third_party" / "licenses.json").read_text())
        manifest["dependencies"] = [entry for entry in manifest["dependencies"] if entry["name"] != AMBIENT_CG]
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
        self.assertIn("required attribution missing: ambientCG Ground037 and Rock023", result.stderr)


if __name__ == "__main__":
    unittest.main()
