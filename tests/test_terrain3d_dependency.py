import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "terrain_3d"
RELEASE_SHA256 = "a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2"


class Terrain3DDependencyTest(unittest.TestCase):
    def test_pinned_linux_plugin_is_enabled_and_attributed(self) -> None:
        self.assertTrue((ADDON / "terrain.gdextension").is_file())
        self.assertTrue((ADDON / "bin" / "libterrain.linux.release.x86_64.so").is_file())
        self.assertIn("enabled=PackedStringArray(\"res://addons/terrain_3d/plugin.cfg\")", (ROOT / "project.godot").read_text())
        self.assertIn("Terrain3D", (ROOT / "third_party" / "licenses.json").read_text())
        self.assertIn(RELEASE_SHA256, (ROOT / "assets" / "third_party" / "terrain3d" / "asset_notes.md").read_text())


if __name__ == "__main__":
    unittest.main()
