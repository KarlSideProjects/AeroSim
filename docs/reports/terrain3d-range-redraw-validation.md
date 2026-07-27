# Terrain Range redraw validation

Implementation commit: `1771bc8`
Design: [`docs/superpowers/specs/2026-07-27-terrain3d-default-scene-redraw-design.md`](../superpowers/specs/2026-07-27-terrain3d-default-scene-redraw-design.md)

This slice replaces the Terrain Range grey-box terrain with the upstream Terrain3D
`v1.0.2-stable` demo valley, moves the flight field onto the 79.7 m mesa at
`(456, -720)`, separates the read-only third-party terrain data from the authored
map data, and fixes the untextured Kenney assets on both Free Flight maps.

## Asset provenance

Upstream regions taken from `project/demo/data` of `TokisanGames/Terrain3D`
`v1.0.2-stable`, matching the vendored addon version, retrieved 2026-07-27. The
hashes are recorded in
[`assets/third_party/terrain3d/asset_notes.md`](../../assets/third_party/terrain3d/asset_notes.md).

`assets/third_party/terrain3d_demo/demo/data/` is now read-only third-party
content. `scripts/author_terrain3d_range.gd` reads it and writes to
`assets/maps/terrain3d_range/data/`, which is what the scene loads. Verified: two
consecutive authoring runs produce a byte-identical output region
(`fac41e40efc5f83651153e3c5ff19173063e44d3d68bb28945eeb94d1b53f8c2`), and the
three third-party region hashes are unchanged after authoring.

## Validation results

All commands run on Godot 4.7-stable, Linux, NVIDIA GeForce RTX 4060 Ti.

- `GODOT_BIN=... godot --headless --import --path .`: pass, no import error or missing dependency.
- `GODOT_BIN=... godot --headless --path . --script res://tests/headless/terrain3d_range_smoke.gd`: pass.
- `GODOT_BIN=... godot --headless --path . --script res://tests/headless/industrial_yard_renderer_smoke.gd`: pass.
- `GODOT_BIN=... scripts/test_industrial_yard_renderers.sh`: pass.
- `GODOT_BIN=... scripts/run_headed_acceptance.sh`: pass, report `passed: true`, all required screenshots present.
- `GODOT_BIN=... scripts/run_gut_tests.sh`: 23 scripts, 275 tests, 1650 assertions pass.
- `GODOT_BIN=... scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5`: pass, artifact reports `completed: true`.
- `scripts/test_native.sh`: pass.
- `scripts/test_shared_map_assets.sh` and `scripts/check_shared_map_assets.sh`: pass.
- `GODOT_BIN=... scripts/test_terrain3d_dependency.sh`: pass.
- `scripts/test_license_scan.sh`: pass, including the GPL rejection fixture.
- `python3 -m unittest tests.test_terrain3d_dependency`: 3 tests pass.
- `python3 -m unittest license_server.test_license_server`: 13 tests pass.
- `scripts/check_hardcoded_airframe_constants.sh`: pass.
- `python3 scripts/check_ui_localization.py`: pass, 281 catalog keys and 5 production files.
- `python3 scripts/check_docs.py`: pass.

### Not run

The GPU performance gate was not run. This slice raises `mesh_lods` from 4 to 7,
raises `mesh_size` from 16 to 48, and adds a GPU ground cover pass, so it does
warrant a measurement. A concurrent benchmark process from another checkout held
the GPU and the AirSim RPC port throughout, which would have contaminated any
result. The gate is a separate workflow and remains outstanding.

## Gate changes

Both Free Flight headless gates gained one assertion: every surface of every
visible Kenney asset must carry an albedo texture. The untextured-model defect
survived because the existing assertions only checked structure, never material.
The guard was verified negatively — pointing `industrial_yard.tscn` back at a
restored `.scn` fails with
`Industrial Yard visual asset building-a surface 0 renders untextured`, and
passes again once reverted.

The hardcoded ground-sample coordinates in
`tests/headless/terrain3d_range_smoke.gd` and `tests/headed/headed_acceptance.gd`
were retargeted to the new flight field, and two ray origins that were pinned to
`y = 50` and `y = 0` now derive from terrain height. No assertion was weakened or
removed.

## Visual evidence

Before CAP-006, visual evidence remains provisional and no human visual review is
requested. Six fixed-view captures were reviewed against the provisional rubric;
the results and input hashes are in
[`terrain3d-range-redraw-visual-verification.json`](terrain3d-range-redraw-visual-verification.json).
Verdict: provisional pass, two low-severity findings, both documented for the
post-CAP-006 pass.

No AirSim upstream source path or symbol was copied or adapted in this slice, so
the AirSim reference audit is not applicable.
