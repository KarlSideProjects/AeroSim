# Terrain3D

- Source: https://github.com/TokisanGames/Terrain3D
- Release: `v1.0.2-stable`
- Archive: `Terrain3D_v1.0.2-stable.zip`
- Archive SHA-256: `a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2`
- License: MIT; the upstream `LICENSE.txt` is retained in `addons/terrain_3d`.
- Runtime scope: the vendored Godot GDExtension is enabled through the project plugin configuration. The Linux release library is retained for qualification; map content is introduced separately.

## Terrain Range height and control data

- Source: `project/demo/data` of the same `v1.0.2-stable` release, retained verbatim under `assets/third_party/terrain3d_demo/demo/data/`. The tag is pinned to match the vendored addon; `main` carries the 1.1.x region format.
- License: MIT, covered by the upstream `LICENSE.txt` retained in `addons/terrain_3d`.
- Retrieved: 2026-07-27.
- File SHA-256: `terrain3d_00_00.res` `ac86dbbe16cfbd7c963aa42598f98101f36017c54eb74e2934b4411d0741e162`; `terrain3d_00-01.res` `b99ee709308c7e6fd9b27b86e6656708726f2080f6c9f6cb33f6176f05c9a221`; `terrain3d_00-02.res` `ef38ace6e235317d96e4f6aa9c2137e335d65af7f2fc2158f2175e23fb996eb3`.
- Geometry: three regions at `(0,0)`, `(0,-1)`, `(0,-2)`, `region_size` 1024 and `vertex_spacing` 1.0, covering x ∈ [0, 1024] and z ∈ [−2048, 1024] with heights from −54.0 m to +365.6 m.
- Write boundary: this directory is read-only third-party content. No AeroSim script may write to it. `scripts/author_terrain3d_range.gd` reads these regions and writes its output to `assets/maps/terrain3d_range/data/`, which is what the Terrain Range scene loads. Keeping the two apart is what makes the hashes above verifiable.

## Terrain Range material inputs

- Material sources: `assets/third_party/terrain3d_demo/demo/assets/textures/ground037_*` (grass and soil/sand tints) and `rock023_*` (rock).
- Source and license: ambientCG Ground037 and Rock023, [CC0 1.0](https://docs.ambientcg.com/license/); the upstream source URLs and semantic mapping are retained in `demo/assets/textures/asset_licenses.txt` and `demo/data/assets.tres`.
- File SHA-256: `ground037_alb_ht.png` `dd93b05e107b15ebd3b94075cb31068a12e490a1fa5e58df3c9cbd54dc33e492`; `ground037_nrm_rgh.png` `02608f96e151ad203724bbc16c5f8df657818c63cb5782725b1bcfe307073975`; `rock023_alb_ht.png` `ad598379cd27e113e78c869b743a77f8d8b442824dbf3fc43dcc03925bb91832`; `rock023_nrm_rgh.png` `a54a3cbbcb3ad4313fad8afea5e98de972cd8e03e28238b7671bda2e24570b3e`.
- Reproducibility: the authored Terrain3D asset list, the deterministic authoring pass in `scripts/author_terrain3d_range.gd`, and its generated output under `assets/maps/terrain3d_range/data/` are all versioned. No runtime download or editor-only paint operation is required.
