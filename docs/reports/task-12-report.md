# Task 12 — GitHub issue #252 report

## Outcome

Issue #252 remains **BLOCKED / not accepted**. The collector now accepts
explicit suite, performance, and platform evidence inputs and fails closed when
they are absent or untrusted. The current run supplied only the known #251
failure artifact:

```text
python3 scripts/qualify_gsp_wayland.py \
  --output build/gsp-wayland-qualification-task12/report.json \
  --godot-bin /home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --performance-evidence build/gsp-idle-qualification-7310191/qualification.failure.json
```

Result: exit `2`, `blocked`.

The #251 prerequisite remains the frozen formal `FAIL`:

- failure: `conditioning_sample_count`
- observed/required: `43479 / 72000`
- frozen run commit: `73101915510e5517bd90f40c24543ec63b226888`
- input SHA-256: `5c04bf9da0f66837d9ca051b18775aa1ebb80fb8a5a60d4378c8049f9c6bb29b`

No D-I-I-D comparison exists, so the required `<1%` performance AC is not
passed and cannot be bypassed by #252.

## Evidence schema and verdict

- `prerequisites.gsp_p0_p4_suite` is the product phase prerequisite with the
  exact keys `GS-P0`, `GS-P1`, `GS-P2`, `GS-P3`, and `GS-P4`. These names are
  not platform subgates and no phase meaning is inferred here.
- `prerequisites.issue_251_performance` is independent of the phase suite.
  The known machine-readable #251 failure is recognized as `fail`; a future
  performance `pass` requires schema, kind, current 40-hex commit, matching
  provenance, reference, and a hash-verified artifact.
- `platform_checks` has the exact semantic keys `native_wayland`, `hidpi_2x`,
  `cursor_focus_roundtrip`, `same_monitor`, `side_by_side`, `cross_monitor`,
  `focus_physics_tick`, `firefox_file_panel_lna`, `chromium_file_panel_lna`,
  `pipewire_recording_no_black_frames`, and `codex_visual_verification`.
- Suite/platform manifests require schema, kind, current 40-hex commit,
  provenance, exact key sets, and an existing SHA-256-matching artifact for
  every `pass` entry. Relative artifact paths resolve from their manifest
  directory. Evaluator input must carry the loader's private validation token;
  raw fabricated status dictionaries cannot pass.
- Final acceptance requires all five phase entries, the performance
  prerequisite, all platform checks, and required OS/desktop/kernel/Godot/
  Firefox/Chromium/display/scaling/Wayland/PipeWire metadata. Accepted
  platform evidence must also contain a non-empty structured GPU observation
  list with actual vendor/model/driver strings; type/device/renderer are
  recorded when available. These values have no allowlist and never
  participate in the verdict. Structured environment topology additionally
  requires `monitor_count >= 2` and non-empty arrangement evidence; the
  `cross_monitor` evidence must match that count and arrangement.

The native Wayland check specifically requires Godot `DisplayServer` evidence;
`WAYLAND_DISPLAY` or `XDG_SESSION_TYPE` environment variables are metadata and
cannot prove it. `codex_visual_verification` is a required provisional check;
human review is separately deferred until CAP-006 and is not a substitute.

## Current environment observations

The read-only collector recorded Ubuntu 26.04 LTS, GNOME Shell 50.1, kernel
7.0.0-28-generic, Godot 4.7, Firefox 153, native-session environment values,
and active PipeWire/WirePlumber/GNOME portal services. Chromium is unavailable;
Google Chrome 150 is recorded separately and is never substituted.

GNOME returned `uint32 0`, which means automatic/unknown scaling. The report
records scale as `unavailable`; only effective compositor/per-monitor evidence
in a supplied platform manifest can prove `hidpi_2x` pass or fail. No platform
manifest was supplied, so there is no topology, cursor/focus, same-monitor,
side-by-side, cross-monitor, physics-focus, browser file-panel/local-network,
PipeWire non-black-frame, or Codex visual evidence. In particular, there is no
trusted topology evidence to compare or accept; collector observations remain
metadata until a platform manifest records the matching structured topology.

PCI and Vulkan GPU vendor/model/type/device/driver/renderer observations are
metadata only. The collector uses an independent DRM `card\d+` sysfs scan and
does not import the benchmark runner or retry GPU collection. The current
collector's metadata is not a platform manifest, so it cannot establish
qualification; accepted platform evidence must provide the structured GPU
observation contract above. No vendor/type/model/driver/renderer restriction
is applied.

## Prior evidence boundary

The inspected #241–#250 reports establish existing GSP launch, transport,
telemetry, tuning, preset, lifecycle, and replay behavior. Their headed or
browser runs are not promoted to final platform qualification: #241–#243 retain
environment-deferred Wayland/HiDPI/focus and standalone browser coverage, and
#244–#250 retain GPU-neutral behavior evidence. The #251 report is the
authoritative frozen performance result used above.

## Verification

```text
python3 -m unittest tests.test_gsp_wayland_qualification
23 tests, 0 failures

python3 -m unittest tests.test_gsp_wayland_qualification \
  tests.test_gsp_issue251_protocol tests.test_gsp_issue251_contract
57 tests, 0 failures

python3 -m py_compile scripts/qualify_gsp_wayland.py tests/test_gsp_wayland_qualification.py
git diff --check
PASS

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
python3 scripts/test_gsp_idle_benchmark_smoke.py
BLOCKED in this read-only environment: Godot could not create user://logs;
with job-local XDG data it could not create the AirSim RPC listener
(ERR_CANT_CREATE). No smoke PASS is claimed.

The smoke failure is not promoted to the formal #251 result: the frozen
machine-readable #251 qualification artifact remains the authoritative
`conditioning_sample_count` FAIL above.
```

No packages, browser binaries, desktop configuration, or GitHub issue comments
were changed. Generated Godot `.uid`, `.import`, and `.translation` files were
not staged.
