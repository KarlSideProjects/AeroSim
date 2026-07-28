# Issue #244 implementation report

## Luna session

No separate Luna session identifier was exposed to the implementation environment. The controlling Codex thread ID was `019fa170-8312-7533-95c3-8651efa0dea7`.

## Selected gain

The initial gain is `simpleflight.rate_p`, the body-rate proportional gain used by the native SimpleFlight controller. It was the smallest safe vertical slice: one existing hard-coded scalar became active controller memory, with the existing value `0.600` preserved and a bounded contract of `0.0` to `2.0`. Only the rate-loop proportional terms consume it.

## Problems and solutions

- Repository indexing through codebase-memory MCP failed with the exact error `Transport closed`. I recorded the failure and used targeted `rg`/`sed` discovery instead.
- The required focused test initially failed to compile because `FlightController` had no `rate_p()` or `set_rate_p()` members. The native active-memory setter/getter and bounded validation were then added; the focused test passed.
- The first GSP tuning contract accepted a dictionary as a numeric value. The validator was tightened to accept only Godot integer or float JSON values; the rerun passed.
- Applying the canonical schema default initially consumed a tuning commit ID even when the active value was unchanged. Native commit accounting now increments only when the active controller value changes.
- Sol finding: `commit_tick` used native 1 kHz substeps. The native commit now receives and stores the public AirSim/GSP physics-frame tick captured at `_physics_process` start.
- Sol finding: the public native setter mutated active tuning directly and trusted a GDScript PX4 pre-check. It was replaced with native validate/stage plus native commit; native authority state is synchronized and checked at both stages and successful PX4 paths mark native external authority.
- Sol finding: no-op behavior was undefined. Native now returns `changed:false`, preserves the commit ID, and runtime records replay tuning only for real changes.
- Sol finding: the old `out_of_contract` branch was unreachable. Validation now clamps finite UI-range overflow with explicit requested/committed/clamped fields and returns a real `native_safety_rejection` if the active controller rejects a staged value.
- Sol finding: disconnect reconciliation and peer correlation were incomplete. Runtime keeps only 16 recent results, hello/telemetry expose latest tuning state, and GSP carries a monotonic connection ID through pending results while stripping it from client acks.
- Sol finding: hardware defaults were reapplied during later flight setup. Defaults now initialize each newly created native controller once, before the first hardware apply; later preset applies do not overwrite tuning.
- Sol finding: server-side `tuning_pending` was write-only. It was removed.
- Sol finding: replay applied tuning before all same-timestamp events and the test never called `replay_session()`. Tuning now executes in recorded event order; the native test runs ordered and reversed same-timestamp sessions and proves divergent replay results.
- Second-review Sol finding: initialization was only indirectly guarded by substeps and nonzero commits. A persistent native `tuning_initialized_` flag now rejects every later initialization attempt, including a different default before any substep or real commit.
- Second-review Sol finding: the previous bounds clamp made `out_of_contract` unreachable. Native now rejects finite values outside `[0.0, 2.0]` without mutation; the centralized native `0.01` step is exposed in the contract and quantizes schema-step input such as `1.234` to `1.23` with `clamped:true`.
- Second-review Sol finding: the two authority/disconnect races were not exercised end to end. The real GSP integration now commits a queued request after its authenticated peer disconnects and reconciles the exact request/commit in reconnect metadata, and separately proves native stage-then-authority-loss rejection with unchanged active memory and commit identity.
- Second-review Sol finding: two #244-added GDScript files still used tabs. `common/gsp/gsp_launcher.gd` and `tests/headless/gsp_tuning_contract.gd` are now four-space indented; the complete first-#244 GDScript file set has no remaining tabs.
- The first review integration run exposed a stale GDExtension missing `initialize_flight_tuning`; the full gate rebuilt it. The rebuilt integration then exposed an invalid test atmosphere and manifest hash, which were corrected to use canonical replay JSON and the native manifest hash.
- The full Godot gate generated untracked `.uid`, `.import`, and translation artifacts. Only those known generated artifacts were removed; no unrelated source or user files were removed.

## TDD and verification

Original implementation RED:

```text
g++ -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native tests/native/test_flight_control.cpp src/native/aerosim_aerodynamics.cpp src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp src/native/aerosim_imu.cpp src/native/aerosim_wind.cpp src/native/aerosim_collision.cpp src/native/aerosim_replay.cpp -o build/tests/test_flight_control_red
```

Result: expected compile failure because `rate_p()` and `set_rate_p()` were not yet defined.

Review-fix RED:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
```

Result: expected failure against the pre-rebuild extension: `Nonexistent function 'initialize_flight_tuning (via call)' in base 'AeroSimNative'`.

GREEN:

```text
g++ -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native tests/native/test_flight_control.cpp src/native/aerosim_aerodynamics.cpp src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp src/native/aerosim_imu.cpp src/native/aerosim_wind.cpp src/native/aerosim_collision.cpp src/native/aerosim_replay.cpp -o build/tests/test_flight_control
build/tests/test_flight_control
```

Result: exit 0.

Review-fix GREEN:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
```

Result: `GSP tuning integration: PASS`.

Second-review RED:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
```

Result against the prior extension: failed the persistent one-shot initialization, native step contract, hard-bound rejection, and updated commit-accounting assertions.

Second-review GREEN:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
```

Result: `GSP tuning integration: PASS`.

Additional results:

- `scripts/test_native.sh`: PASS.
- Second-review native suite: `scripts/test_native.sh` PASS.
- Native replay ordering test: PASS, including `replay_session()` and reversed same-timestamp order.
- Godot `gsp_tuning_contract.gd`: PASS.
- Godot `gsp_tuning_integration.gd`: PASS; one-shot initialization, active/disconnected commit races, paused commit, public tick/ID, native readback, no-op, hard-bound rejection, schema-step quantization, external-authority stage/commit race, reconnect reconciliation, replay recording, and replay application.
- Godot `gsp_transport_contract.gd`: PASS.
- Godot `gsp_telemetry_contract.gd`: PASS.
- GSP transport and telemetry integration checks: PASS.
- `git diff --check`: PASS.
- Final second-review committed-HEAD gate: PASS at `1b26ebd540a7eab9e81614fb8d7976221bf10831`.

  ```text
  RUNNER_TEMP=/tmp/aerosim-gsp-244-review-2 GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh
  ```

  This covered native, license, Python, GUT (276 tests, 0 failures, 0 errors), the GSP tuning integration, headed acceptance, replay integration, and the smoke path. The gate emitted only existing validation/resource warnings; it completed successfully. Only known generated `.uid`, `.import`, and locale translation artifacts were removed afterward.

## Scoped files

- `config/drone_schema.json`
- `common/flight/hardware_config.gd`
- `common/flight/flight_runtime.gd`
- `common/gsp/gsp_launcher.gd`
- `common/gsp/gsp_server.gd`
- `scripts/verify_issue_11.sh`
- `common/gsp/gsp_panel.html`
- `src/native/aerosim_flight_control.hpp`
- `src/native/aerosim_flight_control.cpp`
- `src/native/aerosim_native.hpp`
- `src/native/aerosim_native.cpp`
- `src/native/aerosim_replay.hpp`
- `src/native/aerosim_replay.cpp`
- `tests/native/test_flight_control.cpp`
- `tests/native/test_replay.cpp`
- `tests/headless/gsp_tuning_contract.gd`
- `tests/headless/gsp_tuning_integration.gd`
- this report

## Limitations and headed evidence

The full gate ran headed acceptance, but CAP-006 has not passed, so no formal human visual/usability review was requested. The implementation has no GPU vendor, device-type, Vulkan ICD, or NVIDIA allowlist. The headed environment happened to report `/usr/share/vulkan/icd.d/nvidia_icd.json`, Vulkan `1.4.312`, and `NVIDIA GeForce RTX 4060 Ti`; this is recorded as evidence only, not as a requirement.

Only the first SimpleFlight scalar is exposed. Additional gains, richer editing controls, and cross-authority tuning remain deferred until this vertical slice proves stable.
