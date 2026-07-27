# Issue #250 report

## Outcome

Complete replay recordings now use schema v5. Every newly recorded event carries a cumulative session replay physics tick and contiguous per-tick event order. v5 loading validates and replays events individually in authoritative `(physics_tick, event_order)` order; timestamps remain the stepping clock. The legacy v4 loader accepts only recordings without ordering fields and preserves timestamp/file-order replay without synthesizing ordering metadata.

Markers are authenticated, bounded GSP inputs and are recorded as v5 events at the current authoritative tick. The supported simulation GSP surface is limited to pause/resume and uses the existing lifecycle, sequencing, and reliable acknowledgement paths. Preset provenance is accepted by native replay validation, including migration/load commits.

Derived JSONL is produced only after successful authoritative replay loading. It includes schema and ordering facts, reports v4 as timestamp/file order, and never invents v4 tick/order values.

The runtime tick is cumulative for the replay session and advances before reset-pending early returns, so an AirSim session reset cannot make the authoritative replay tick repeat or regress. No GPU vendor, device, type, or driver-specific behavior was added.

The canonical simulation wire message is exactly `t="sim_cmd"` with `d.cmd` and an optional empty bounded Dictionary `d.args`; only `pause` and `resume` are accepted, aliases and the invented `operation` field are rejected, and replies remain reliable `sim_cmd_ack` messages. Replay tick and append failures are sticky and session-fatal while recording is active. Marker, simulation, tuning, Quick Adjust, begin, physics-step, and finish paths propagate those failures; pause/resume state is not changed before a successful append, tuning and Quick Adjust do not report success after failure, and finish never certifies an incomplete recording. Non-recording tuning and preset commits remain ordinary successful flows.

Quick Adjust binding recording still precedes persistence, but any active-session settings load/save failure now makes the replay unrecoverable, so an unpersisted binding cannot be certified. The former production `replay_recording_event_count` method was removed: the authenticated WebSocket test proves rejected marker, simulation, and tuning requests add no events by comparing the complete final literal event sequence with the accepted expected sequence.

## Tests

- Native TDD coverage: schema v5 round-trip, same-tick ordering, first-order-zero and overflow-safe v5 rejection, v4 compatibility without false precision, recorder tick/order guards, sticky append/order failure, side-effect ordering after successful append, finish refusal after append failure, marker bounds/round-trip, derived JSONL provenance, preset source validation, and a genuine schema-v4 same-timestamp mixed-event fixture with per-event checkpoint parity.
- Headless contract coverage: exact `sim_cmd`/reliable ACK validation, whitespace and multibyte marker byte boundaries, and monotonic replay tick across `AirSimSession.reset()`.
- Real authenticated WebSocket replay integration: registers real tuning, Quick Adjust, preset, marker, and simulation providers; authenticates; records transient/final panel commits, persisted Quick Adjust binding/commit, confirmed preset migration, pause, and marker; exercises malformed/rejected marker/simulation/tuning requests; reloads the persisted Quick Adjust profile; compares the exact accepted ordered event sequence and all relevant input/provenance values after load/replay; and compares derived JSONL rows only after replay succeeds.
- Focused commands passed:

  `scripts/test_native.sh`

  `/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/headless/gsp_preset_contract.gd`

  `/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/headless/gsp_tuning_contract.gd`

  `/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/headless/quick_adjust_integration.gd`

  `/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/headless/gsp_replay_integration.gd`

- Exact committed-HEAD gate passed:

  `RUNNER_TEMP=/tmp/aerosim-gsp-250 GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh`

  Result: exit 0. Native, license, GSP contract/integration/stress, rebuilt native extension, headed acceptance, replay integration, GUT (277 tests, 0 failures, 0 errors), smoke, and terrain checks passed.

Codebase-memory transport was available and used for repository discovery; no direct-search fallback was needed for code discovery. No ledger or GitHub changes were made.

## Commits

- `056a594 Add schema v5 authoritative replay events`
- `537bc55 Fix preset replay test value`
- `1f3ccc2 Document issue 250 replay gate`
- `ef094bb Fix issue 250 replay review findings`
- `0038239 Fix issue 250 replay review findings`
- `02c36f0 Preserve replay pause override contract`
- `afd921b Fix issue 250 replay failure handling`
