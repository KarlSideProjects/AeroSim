# Free3D Drone Costume

- Source: https://free3d.com/3d-model/drone-costume-411845.html
- Source author: zakardian
- Download archive: `17-drone_costum.zip`
- Archive SHA-256: `35ff17fb94a4551adf01b6927022ca0367d75a4af6343ddfd5d385b81d7d1394`
- Imported source: `drone_costum.fbx`
- Godot runtime scene: `drone_costum_godot.scn` (self-contained Godot 4.7 conversion)
- License shown by source page: Personal Use License
- Project use: non-commercial personal project only
- Conversion: the runtime SCN bakes the mesh and stable material colors; source textures remain alongside the original FBX for provenance.

The converted SCN is loaded at runtime by `drone_visual_loader.gd`. The
original physics body and collision shape remain independent. If the asset is
unavailable, the scene keeps its box mesh and displays a load-failure status.
