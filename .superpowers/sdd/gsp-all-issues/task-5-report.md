# Issue #245 implementation report

## Luna session

`CODEX_THREAD_ID=019fa1b9-029a-7950-a0bb-54370b0bb2a1`. No separate Luna
session identifier was exposed; this is the controlling Codex thread ID.

## Selected parameter set and active consumers

The initial registry is exactly these four canonical Hardware configuration
descriptors:

- `simpleflight.rate_p`, default `0.600`, range `[0.0, 2.0]`, step `0.01`.
- `simpleflight.angle_p`, default `15.0`, range `[0.0, 40.0]`, step `0.1`.
- `simpleflight.rate_i`, default `0.020`, range `[0.0, 1.0]`, step `0.001`.
- `simpleflight.rate_d`, default `0.005`, range `[0.0, 1.0]`, step `0.001`.

The exact native consumers were traced before implementation:

- `FlightController::control_substep`: `angle_p_` scales Angle-mode attitude
  error into rate setpoint.
- `FlightController::control_substep`: `rate_p_` scales body-rate error.
- `FlightController::control_substep`: `rate_i_` integrates body-rate error.
- `FlightController::control_substep`: `rate_d_` scales the filtered derivative.

Hardware configuration registry JSON is the descriptor authority. Native
`FlightController` fields are the active-value authority. Registry hashing
uses sorted-key canonical serialization of only the tuning descriptor array,
so it is deterministic and distinct from a broad preset/configuration hash.

## Problems encountered and solutions

- `codebase-memory-mcp` indexing failed with the exact error
  `tool call error: tool call failed for codebase-memory-mcp/index_repository
  Caused by: Transport closed`. I recorded the failure and used targeted
  `rg`/`sed` discovery as required.
- The first focused contract run was intentionally RED: the existing GspServer
  had no `validate_set_tuning_batch_message` method. The batch validator and
  descriptor-driven contract were then added.
- The first extension build was RED because `Dictionary::get` requires a
  default argument in the pinned godot-cpp API. `change.get("value", Variant())`
  fixed it; the extension rebuilt successfully.
- The first integration run found a warning-as-error from an inferred Variant
  in `gsp_validate_all`. The local variable is now explicitly typed
  `Dictionary`.
- The stress script initially printed both PASS and FAIL because `quit(0)` does
  not return from the current GDScript function. An explicit return after the
  successful quit fixed the harness.
- No high-value ambiguity remained after tracing the four native consumers, so
  Sol-high was not invoked.

## Atomicity, apply timing, replay, and multi-panel decisions

- `stage_flight_tuning_batch` validates and quantizes every member into a local
  vector before replacing staged state. Duplicate keys are coalesced to the
  final value. Any invalid member clears staging and returns without changing
  active memory.
- `commit_flight_tuning` applies the complete validated vector, rolls back
  already-applied members if a native setter rejects, and increments one
  `commit_id`/tick for the whole changed batch. No-op batches preserve the
  identity and report `changed: false`.
- Runtime requests drained at one physics boundary are coalesced again before
  the native swap. Paused requests commit immediately through the same native
  operation. `next_physics_step` remains pending until the boundary; an
  explicit timing contract reports `immediate`, `reset_required`, and
  `restart_required` without pretending they are committed.
- The existing reliable queue carries `tuning_ack` to the origin and
  `tuning_commit` with the same commit identity and committed-values map to all
  authenticated panels. The server remains capped at two authenticated peers.
- Actual changed native batch members are each recorded through the existing
  Flight Replay tuning event. Rejected and no-op requests are not recorded.
- `gsp_validate_all` compares every registry descriptor to native active-memory
  introspection and reports a deliberately disconnected descriptor as a
  read-back mismatch.

## TDD and verification

RED:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_contract.gd
```

Result: expected parse failure because `GspServer.validate_set_tuning_batch_message()` did not exist.

The first full-gate build also produced a compile failure at
`src/native/aerosim_native.cpp:1651` because `Dictionary::get` had no one-argument
overload. That failure is included above and was corrected before GREEN.

GREEN:

```text
scripts/test_native.sh
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_contract.gd
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_tuning_stress.gd
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_transport_contract.gd
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_contract.gd
git diff --check
```

Results: all passed. The tuning integration covers native batch all-or-nothing
behavior, duplicate-key finalization, paused/physics-step behavior, native
read-back, authority rejection, reconnect reconciliation, replay recording,
two authenticated panels, and disconnected-descriptor validation. The stress
run covers 1,500 deterministic messages at 50 messages/second for 30 seconds,
with bounded pending/result/recent queues, finite native state, and final value
`1.75`.

The mandated committed-HEAD gate is run after this report and implementation
are committed:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-245 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

## Scoped files and honest limitations

Changed files are limited to the canonical schema/configuration path, native
SimpleFlight controller and GDExtension binding, existing GSP runtime/server/
panel, the verification gate, focused native/headless tests, the deterministic
stress test, and this report.

The initial surface intentionally exposes only the four SimpleFlight gains;
there is no generic parameter framework, new dependency, or second runtime
state authority. Immediate/reset/restart timing is represented and reported
honestly, but no unrelated visual or restart-required setting was added merely
to manufacture a tuning descriptor.

## GPU neutrality

No GPU vendor, device-type, adapter, Vulkan ICD, NVIDIA, integrated, discrete,
virtual, or software-adapter requirement was added. GPU evidence remains
observational only.
