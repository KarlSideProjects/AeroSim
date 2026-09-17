# GSP Three.js runtime

- Source package: `three` 0.180.0
- License: MIT; see `THREE-LICENSE`.
- Generated runtime: `three-0.180.0.global.min.js`
- Generated SHA-256: `9e80ed95a3bcbb77bb1d6024de9f7f4cc7d6a9745a322f88052edd29e9faa737`
- Build entry: `scripts/gsp_three_entry.js`
- Build command: `npx esbuild scripts/gsp_three_entry.js --bundle --format=iife --global-name=THREE --minify --outfile=common/gsp/assets/three-0.180.0.global.min.js`
- Runtime scope: a self-contained classic script for GSP's `file://` panel; it exports `THREE` and `RoomEnvironment` without network access.

# GSP drone geometry package

- Asset: `gsp_drone_geometry.js`
- Original source: AeroSim-authored parametric Quad-X geometry; no third-party
  model, mesh or texture is vendored. Written for
  https://github.com/jhihweijhan/AeroSim/issues/302.
- Dimensional evidence: `parametric_from_configuration`. Motor placement,
  propeller diameter, blade count, motor stator/KV, FPV camera angle and centre
  of mass are read from the active hardware configuration
  (`aircraft.motor_layout`, `propeller.*`, `motor.*`, `fpv.camera_angle_deg`,
  `aircraft.cg_offset_m`). Body, motor-shell and propeller-shell dimensions are
  nominal 5-inch 6S values recorded in `geometry.body`, `geometry.motor` and
  `geometry.propeller`; they are not measured from a named frame and no public
  CAD backs them.
- Geometry classification: `Nominal geometry`. The panel reports
  `Real geometry` only when the recorded evidence class is a manufacturer CAD,
  a manufacturer drawing or a measured specimen, with at least one evidence
  document, release redistribution rights, an allowlisted SPDX licence, the
  required attribution, and a hashed asset list.
- License: MIT, (c) AeroSim contributors, as a separately licensed geometry
  component. The repository-wide noncommercial license does not replace this
  component grant; see [scope notices](../../../LICENSING.md).
- Required attribution: `AeroSim parametric Quad-X geometry, (c) AeroSim
  contributors, MIT`.
- Redistribution disposition: `release`.
- Recorded SHA-256: reproduce with
  `sha256sum common/gsp/assets/gsp_drone_geometry.js`; the same digest is
  recorded in every `config/drones/*.json` `geometry.provenance.assets` entry
  and in `HardwareConfig.FACTORY_DEFAULT`, and is verified by
  `scripts/check_gsp_drone_geometry.py` (use `--write` to refresh it).
- Required loader: the geometry package builds Three.js meshes, so the pinned
  `three-0.180.0.global.min.js` above is listed and hashed in the same
  `geometry.provenance.assets` list and installed by the same panel bundle.
- Runtime scope: a debug-only presentation asset installed beside the local
  `file://` panel. It builds Three.js meshes and never touches physics,
  collision, sensor mounts, control authority or replay state.
