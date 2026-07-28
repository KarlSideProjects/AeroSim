# Task 10 brief — GitHub issue #250

Base commit: `f94c4c9`

Implement: record GSP tuning sessions and markers in the existing authoritative
Flight Replay system.

## Acceptance

- Authoritative replay events cover every actual committed tuning value,
  including transient and final panel commits, Quick Adjust commits, persisted
  binding changes, confirmed preset commits/migrations, supported GSP
  simulation commands, and labeled markers.
- Record authoritative `physics_tick` and deterministic zero-based
  `event_order` for every replay event. Events sharing one tick preserve their
  accepted/committed order through serialize → load → replay. Do not infer
  order from wall clock or JSON object ordering.
- Markers contain a validated non-empty label and optional note, are recorded
  at the authoritative current physics tick, and can delimit tuning runs.
- Replay reproduces the recorded input values at every
  `(physics_tick, event_order)` pair, including same-tick multi-event cases.
- Replay promises input-sequence reproducibility only. Documentation, schema,
  and tests must not claim bit-exact floating-point output across builds,
  compiler options, SIMD paths, or hardware.
- A JSONL session export is derived deterministically from authoritative replay
  events and can be regenerated. Runtime replay/load never consumes JSONL and
  no second recorder/authority is introduced.
- Current complete-replay files remain compatible according to the
  repository’s existing compatibility contract. If the schema must advance,
  use the minimum backward-compatible loader/migration needed; do not silently
  reinterpret old event order.
- Existing replay, tuning, preset, Quick Adjust, transport, headed, and smoke
  suites remain green.

## Protocol/runtime scope

- Add the minimum authenticated GSP message/provider seams needed for:
  - `mark` with `{label, note?}`;
  - supported simulation commands already backed by authoritative runtime
    behavior. Keep the allowlist narrow (pause/resume and only existing
    deterministic step/reset operations that can be proven safely); no shell,
    filesystem path, arbitrary method, or generic command execution.
- Validate message sizes/types/strings/sequence at the existing GSP trust
  boundary. Marker labels/notes and command arguments must be bounded.
- Markers and supported commands must use the same request correlation,
  reliable queue, auth, and generation/peer lifecycle already implemented.
- Do not broaden GSP binding, credential, origin, filesystem, or network scope.

## Replay integration constraints

- Extend `src/native/aerosim_replay.*` and the existing
  `ReplaySessionRecorder`; do not create a parallel replay/session engine.
- Centralize tick/order assignment in the authoritative recorder/runtime seam
  so all event types cannot drift. Same-tick order must be monotonic and reset
  only when the physics tick advances.
- Preserve timestamp behavior required by existing replay stepping, but
  tick/order is the authoritative ordering key for the new tuning-session
  contract.
- Parameter replay records committed values from the native commit result, not
  panel intent. Preserve requested/committed/clamped/source/Quick Adjust slot
  provenance.
- Preset application must remain atomic and use the existing tuning commit
  path. Record the exact committed sequence/source without a second preset
  mutation path.
- Quick Adjust binding and commit replay must continue through the existing
  SettingsStore/tuning paths.
- Derived JSONL must be generated from serialized/loaded authoritative replay
  events, use canonical event order, and expose no replay-ingest path.
- Keep implementation and validation GPU vendor/type/device/driver neutral.

## Required TDD evidence

1. Native RED/GREEN tests for:
   - same-tick mixed event types receiving stable `physics_tick` and
     `event_order`;
   - serialize/load/replay preserving exact ordered input values;
   - marker label/note validation and round trip;
   - current schema compatibility;
   - deterministic JSONL derivation and proof it is output-only.
2. Headless real GSP/WebSocket RED/GREEN integration proving:
   - authenticated marker and supported command requests;
   - transient/final panel commit, Quick Adjust commit/binding, preset
     commit/migration, command, and marker all reach authoritative replay;
   - at least two different event types in one physics tick have distinct,
     deterministic order;
   - rejected/malformed requests create no replay events.
3. Replay the recorded session and compare the ordered
   `(physics_tick, event_order, type, input values)` sequence to the original.
4. Run narrow tests first, then the exact full committed-HEAD gate:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-250 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

## Handoff

Write a detailed problem/solution/test report to `task-10-report.md`, commit all
task changes, remove only known generated Godot artifacts, and leave the
worktree clean. Do not edit the ledger or GitHub issue.
