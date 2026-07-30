import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENE = ROOT / "levels" / "free_flight" / "terrain3d_range.tscn"
MATERIAL_DIRECTORY = ROOT / "assets" / "maps" / "terrain3d_range"
ADDON_DIRECTORY = ROOT / "addons" / "terrain_3d" / "extras" / "particle_example"
NOTICE = "Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors."


class Terrain3DRangeGrassMaterialsTest(unittest.TestCase):
    def test_grass_uses_shared_project_owned_materials_at_the_visual_wind_sample(self) -> None:
        scene = SCENE.read_text(encoding="utf-8")
        process_material = MATERIAL_DIRECTORY / "grass_process_material.tres"
        blade_material = MATERIAL_DIRECTORY / "grass_blade_material.tres"
        process_shader = MATERIAL_DIRECTORY / "grass_process.gdshader"
        blade_shader = MATERIAL_DIRECTORY / "grass_blade.gdshader"

        self.assertIn('path="res://assets/maps/terrain3d_range/grass_process_material.tres"', scene)
        self.assertIn('path="res://assets/maps/terrain3d_range/grass_blade_material.tres"', scene)
        self.assertIn('process_material = ExtResource("8")', scene)
        self.assertIn('mesh_material_override = ExtResource("9")', scene)
        self.assertIn('[node name="VisualWindSample" type="Marker3D" parent="."]', scene)
        self.assertIn('position = Vector3(480, 79.7, -740)', scene)
        self.assertIn('[node name="VisualWindController" type="Node" parent="."]', scene)

        for source in [process_material, blade_material, process_shader, blade_shader]:
            self.assertTrue(source.is_file(), source)
        self.assertIn('path="res://assets/maps/terrain3d_range/grass_process.gdshader"', process_material.read_text(encoding="utf-8"))
        self.assertIn('path="res://assets/maps/terrain3d_range/grass_blade.gdshader"', blade_material.read_text(encoding="utf-8"))
        self.assertTrue(all(NOTICE in shader.read_text(encoding="utf-8") for shader in [process_shader, blade_shader]))

    def test_project_owned_material_resources_leave_the_addon_boundary_intact(self) -> None:
        process_material = (MATERIAL_DIRECTORY / "grass_process_material.tres").read_text(encoding="utf-8")
        for setting in [
            "shader_parameter/min_scale = Vector3(0.1, 0.32, 0.1)",
            "shader_parameter/max_scale = Vector3(0.1, 0.62, 0.1)",
            "shader_parameter/wind_speed = 0.02",
            "shader_parameter/wind_strength = 0.55",
            "shader_parameter/surface_slope_min = 0.87",
            "shader_parameter/distance_fade_ammount = 0.66",
        ]:
            self.assertIn(setting, process_material)
        particle_scene = (ADDON_DIRECTORY / "Terrain3DParticles.tscn").read_text(encoding="utf-8")
        for setting in ["instance_spacing = 0.25", "rows = 96", "amount = 9216", "min_draw_distance = 60.0", "particle_count = 230400"]:
            self.assertIn(setting, particle_scene)
        self.assertIn(
            "shader_parameter/wind_direction = Vector2(1, 1)",
            (MATERIAL_DIRECTORY / "grass_blade_material.tres").read_text(encoding="utf-8"),
        )

    def test_grass_blades_have_bounded_natural_wind_deformation(self) -> None:
        scene = SCENE.read_text(encoding="utf-8")
        blade_shader = (MATERIAL_DIRECTORY / "grass_blade.gdshader").read_text(encoding="utf-8")
        visual_wind = (ROOT / "common" / "maps" / "terrain_range_visual_wind.gd").read_text(encoding="utf-8")

        self.assertIn("section_segments = 3", scene)
        for source in [blade_shader, visual_wind]:
            self.assertIn("wind_phase", source)
        for source in ["MAX_BEND_METERS", "smoothstep", "INSTANCE_CUSTOM.rg", "coherent_gust"]:
            self.assertIn(source, blade_shader)
        self.assertIn("_expand_particle_bounds", visual_wind)
        self.assertIn("custom_aabb.grow(PARTICLE_AABB_MARGIN_METERS)", visual_wind)


if __name__ == "__main__":
    unittest.main()
