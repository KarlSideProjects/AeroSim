# GSP Drone Geometry

Source: <https://github.com/jhihweijhan/AeroSim/issues/302>

The GSP panel renders the configured Vehicle Instance as a Quad-X airframe built
at real-world size. This document is the contract for that geometry: where its
dimensions come from, when the panel may call it real, and how it is verified.

## Authority

Geometry is presentation only. It never touches physics, collision, sensor
mounts, control authority or replay state; `hardware_config.gd` validates the
`geometry` section but does not apply any of it to the native runtime.

Everything the renderer draws is derived from the active hardware configuration:

| Rendered property | Configuration source |
| --- | --- |
| M1-M4 placement | `aircraft.motor_layout` (FRD metres, same data the physics torque arms use) |
| M1-M4 numbering | `motor_order` index, Betaflight quad-X |
| Propeller spin direction | `spin_direction` |
| Propeller diameter and blade count | `propeller.diameter_in`, `propeller.blades` |
| Motor label text | `motor.stator`, `motor.kv` |
| FPV camera uptilt | `fpv.camera_angle_deg` |
| Centre-of-mass marker | `aircraft.cg_offset_m` |
| Reported wheelbase | `frame.wheelbase_m` |
| Frame, canopy, stack, pack, motor-shell and blade shell dimensions | `geometry.body`, `geometry.motor`, `geometry.propeller` |

`common/gsp/assets/gsp_drone_geometry.js` reads every airframe dimension from the
configuration; the proportions it does hold (how much narrower the top plate is
than the bottom, how far a motor bell tapers) are shell shape, not measurements
any preset supplies. `scripts/check_hardcoded_airframe_constants.sh` now scans
the file for the specific airframe values it rejects elsewhere, which is a guard,
not a proof. The behavioural proof is that the freestyle and race presets render
different aircraft from the same code, asserted in
`tests/test_gsp_drone_geometry.js`.

## Geometry classification

The panel reports `Real geometry` only when `geometry.provenance` satisfies all
of the following, and `Nominal geometry` otherwise, listing the reasons:

- `dimensional_evidence.evidence_class` is `manufacturer_cad`,
  `manufacturer_drawing` or `measured_specimen`;
- at least one evidence document with a title and a URL;
- `redistribution` is `release`;
- `license.spdx` is on `config/license_allowlist.json`;
- the required attribution is recorded when `attribution_required` is true;
- every listed asset carries a 64-hex sha256;
- no geometry warning is active.

Two warnings currently exist. `propeller_overlap` fires when adjacent propeller
discs intersect. `wheelbase_disagrees_with_motor_layout` fires when
`frame.wheelbase_m` differs from the motor-to-motor diagonal implied by
`aircraft.motor_layout` by more than 1%; both shipped presets trip it, and the
panel prints both the stated and the layout wheelbase side by side. Fixing that
disagreement means changing configuration data that the physics torque arms read,
so it belongs to a separate change, not to the renderer.

The shipped `5-inch 6S` presets report **Nominal geometry**. Their shells are
AeroSim-authored parametric geometry with typical 5-inch 6S dimensions rather
than measurements of a named frame, and `frame.wheelbase_m` disagrees with
`aircraft.motor_layout` (whose motor radius implies a wider motor-to-motor
diagonal), so no real frame can be claimed. Visual polish must never be read as
dimensional fidelity.

## Bundle and provenance

The geometry package is a versioned bundle asset: `GspLauncher.PANEL_ASSET_PATHS`
installs it beside `panel.html`, and the panel loads it from the bundle over
`file://` with no network access. Provenance, licence, attribution,
redistribution disposition and asset hashes live in
`geometry.provenance` in every preset and in `HardwareConfig.FACTORY_DEFAULT`;
`common/gsp/assets/asset_notes.md` records the same facts for the asset itself.

## Verification

| Command | What it proves |
| --- | --- |
| `node tests/test_gsp_drone_geometry.js` | Spec derivation, M1-M4 mapping, spin, clearance, classification rules, and a Three.js model built to the configured size outside a browser. |
| `python3 scripts/check_gsp_drone_geometry.py` | Bundle completeness, reproducible asset hashes, provenance completeness, release redistribution, licence allowlist parity, and the computed classification. Add `--write` after editing the asset. |
| `scripts/test_license_scan.sh` | Runs the check above and proves it rejects `tests/fixtures/geometry_not_redistributable.json`. |
| `scripts/check_hardcoded_airframe_constants.sh` | No airframe constants in the geometry or visual code. |
| `python3 scripts/check_gsp_geometry_browser.py` | Real Chrome over `file://` with name resolution blocked: the model loads, measures the configured span, maps M1-M4 with drawn labels, and the panel badge matches the classification. Wired into `scripts/verify_issue_11.sh`; needs Chrome (`CHROME_BIN`, default `/usr/bin/google-chrome`). Add `--headed --hold 120 --screenshot out.png` for visual evidence. |
| `node tests/test_gsp_visual_state.js`, `node tests/test_gsp_panel_behavior.js` | Telemetry mapping and the panel geometry card, including the unavailable path. |
| `tests/gut/test_hardware_config.gd`, `tests/gut/test_gsp_launcher_assets.gd` | Schema validation, provenance rejection, bundle install, recorded-hash match, and that geometry never reaches the physics runtime. |
