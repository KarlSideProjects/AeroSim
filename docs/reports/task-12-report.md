# Task 12 — GitHub issue #252 report

## Outcome

Issue #252 remains **BLOCKED / not accepted**. The new machine-readable evidence
collector wrote `build/gsp-wayland-qualification-task12/report.json` and returned
exit code `2` with qualification status `blocked` (SHA-256
`e7c1fc2ce141800ec1f76059671282bbdfd545d9472211389dccee62fc6dc3de`). It does
not claim platform qualification PASS.

The mandatory #251 prerequisite is preserved as a real failure:

- source: `build/gsp-idle-qualification-7310191/qualification.failure.json`
- failure: `conditioning_sample_count`
- observed/required: `43479 / 72000`
- frozen formal run: commit `73101915510e5517bd90f40c24543ec63b226888`

No D-I-I-D comparison exists, so the required `<1%` physics-tick performance
AC is not passed and cannot be bypassed by #252.

## Implementation

- Added `scripts/qualify_gsp_wayland.py`, a read-only stdlib collector and
  fail-closed evaluator for the five required non-human gates `GS-P0` through
  `GS-P4`.
- Added `tests/test_gsp_wayland_qualification.py` covering the frozen #251
  failure, required-gate enforcement, GPU-metadata neutrality, Chromium
  absence, and the open-ended `>=2x` HiDPI threshold.
- The evaluator only reads gate/prerequisite statuses. GPU vendor, model,
  adapter type, driver, and renderer fields are metadata and cannot affect its
  verdict.
- Firefox and the exact `chromium` command are collected separately. The
  available `google-chrome` command is recorded under
  `google_chrome_observation_only`; it is never substituted for Chromium.
- Human visual/usability review is recorded as deferred until CAP-006.

## Current recorded environment

The report records Ubuntu 26.04 LTS, GNOME Shell 50.1, kernel
7.0.0-28-generic, Godot 4.7, native Wayland (`wayland-0`), the observed X11
display variable, GNOME scaling output `uint32 0`, Firefox 153, and Chromium
unavailable. Google Chrome 150 is present only as a separate observation.

PCI and Vulkan metadata records the AMD `amdgpu` and NVIDIA `nvidia` devices,
their models/types, drivers, and the available Vulkan renderer/driver entries,
including the CPU `llvmpipe` entry. PipeWire, WirePlumber,
`xdg-desktop-portal`, and `xdg-desktop-portal-gnome` were active. No compositor
topology, cross-monitor, browser file-panel/local-network, external
focus/cursor, physics-focus, or PipeWire non-black-frame run was performed;
those are recorded as not run or blocked rather than inferred from metadata.

## Gate status

| Gate | Status | Reason |
| --- | --- | --- |
| GS-P0 native Wayland launch/focus | `not_run` | Existing headed runner retained; no new live qualification claimed |
| GS-P1 HiDPI/monitor/cursor workflows | `blocked` | Recorded scaling is below the `>=2x` requirement; topology evidence not run |
| GS-P2 Firefox/Chromium panel workflows | `blocked` | Chromium command is unavailable; both browser behavior checks are not run |
| GS-P3 focus versus physics/performance | `not_run` | #251 frozen performance prerequisite failed |
| GS-P4 PipeWire/GNOME portal recording | `not_run` | Services are present, but recording and black-frame verification were not run |

The manifest requires every gate to be `pass` and requires the #251
performance prerequisite to be `pass`; therefore its final status is
`blocked`.

## Prior evidence boundary

The inspected #241–#250 reports establish the existing GSP launch, transport,
telemetry, tuning, preset, lifecycle, and replay behavior. Their headed or
browser runs are not silently promoted to this final Ubuntu platform
qualification: #241–#243 explicitly retain environment-deferred Wayland,
HiDPI, focus, and standalone Firefox/Chromium coverage, while #244–#250 retain
GPU-neutral behavior evidence. The #251 report is the authoritative frozen
performance result used above.

## Verification

```text
python3 -m unittest tests.test_gsp_wayland_qualification
5 tests, 0 failures

python3 -m py_compile scripts/qualify_gsp_wayland.py tests/test_gsp_wayland_qualification.py
git diff --check
PASS

python3 scripts/qualify_gsp_wayland.py \
  --output build/gsp-wayland-qualification-task12/report.json \
  --godot-bin /home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64
exit 2: GSP Wayland qualification: BLOCKED
```

No packages, browser binaries, desktop configuration, or GitHub issue comments
were changed. Generated Godot `.uid`, `.import`, and `.translation` files were
not staged.
