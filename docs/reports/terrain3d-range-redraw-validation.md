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

## Software-rendering cost

This slice raises `mesh_lods` from 4 to 7, raises `mesh_size` from 16 to 48, and
adds a GPU ground cover pass, so it needed a measurement against the tightest
budget in CI: `tests/test_performance_runner.py` wraps
`scripts/run_performance_benchmark.sh --mode smoke --warmup-seconds 0 --seconds 0.1`
in a hard 60 s timeout, and the CI step runs it under llvmpipe and Xvfb.

Measured on an idle machine (1-minute load average 1.0), three runs per
configuration, same Godot 4.7-stable and same debug GDExtension throughout:

| Configuration | Runs | Delta vs main |
| --- | --- | --- |
| `main` | 3.8 s, 3.8 s, 3.7 s | — |
| This slice | 22.8 s, 22.9 s, 23.2 s | +19.1 s |
| This slice, no ground cover | 9.3 s, 9.4 s, 9.4 s | +5.6 s |
| This slice, clipmap 5 / 32 | 18.3 s, 18.3 s, 17.4 s | +14.2 s |
| This slice, clipmap 5 / 32, no ground cover | 5.9 s, 5.9 s, 6.1 s | +2.2 s |

The GPU ground cover carries 13.5 s of the 19.1 s added, and the larger clipmap
carries 4.9 s. At 22.9 s the slice sits well inside the 60 s budget, so nothing
was traded away to land it, but the headroom drops from 15.8x on `main` to 2.6x.
Anything else added to this map should be measured the same way before it lands.

Earlier runs of this gate did time out. Those measurements were taken while a
runaway `codebase-memory-mcp` process held roughly 28 of the machine's 32 cores,
which put the 1-minute load average above 40 and stretched the same 22.9 s of
work past the 60 s timeout. Repeated runs of one configuration varied between
61 s and 104 s under that load, so no attribution was possible until the machine
was idle. The numbers above supersede them.

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

`tests/gut/test_collision_probe_body.gd` now settles the body for one physics
frame after `add_child` before queuing the reset. The test previously added the
body and queued the reset in the same frame, then awaited a single physics frame
for the acknowledgement, but a body added mid-frame is not guaranteed to be
simulated in the step that follows. Measured in isolation the old pattern missed
106 of 300 attempts; the suite's timing usually hid that, and it surfaced as an
intermittent failure once this slice changed how long the default map takes to
load. The assertion is unchanged.

The AirSim vertical commands this map depends on were fixed separately in #255:
`takeoff`, `land` and the `moveByVelocityZ` family resolved their targets against
world height rather than the spawn origin, which commanded a descent from this
map's 79.7 m spawn. `scripts/test_airsim_rpc_client.sh` failed 3 of 3 runs on
this branch before that fix and passes 3 of 3 after it.

## Visual evidence

Before CAP-006, visual evidence remains provisional and no human visual review is
requested. Six fixed-view captures were reviewed against the provisional rubric;
the results and input hashes are in
[`terrain3d-range-redraw-visual-verification.json`](terrain3d-range-redraw-visual-verification.json).
Verdict: provisional pass, two low-severity findings, both documented for the
post-CAP-006 pass.

No AirSim upstream source path or symbol was copied or adapted in this slice, so
the AirSim reference audit is not applicable.
