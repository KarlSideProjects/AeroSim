# Task 11 brief — GitHub issue #251

Base commit: `c4b01bdb73792bb805598355221bfb169e15b01e`

Implement: preserve GSP reliability and physics performance when an
authenticated browser is slow, throttled, backgrounded, refreshed, or killed.

## Acceptance

- Outbound pressure suppresses lossy telemetry before reliable traffic. When
  pressure clears, a peer receives the newest telemetry snapshot only; no
  telemetry backlog is replayed.
- The WebSocket native outbound capacity, telemetry-suppression threshold,
  hard-close threshold, maximum reliable message size, reliable queue count,
  and reliable queue byte bound have explicit, test-enforced invariants. No
  configured state may make the reliable bound unreachable or let the native
  buffer exceed the hard-close policy before it can be observed.
- Crossing the hard-close threshold records a local failure and closes only
  the impaired peer without pausing, failing, or materially delaying physics.
- Reliable overflow performs one bounded best-effort attempt to report
  `error{code:"overflow"}`, records whether that attempt was made/accepted by
  the local transport, and closes the peer. It must never claim that the final
  error was delivered or silently discard an already accepted reliable ACK.
  Avoid recursive overflow/error queuing.
- Stalled, backgrounded, refreshed, and killed browser scenarios leave queues
  and peer sets bounded, reclaim peers within existing lifecycle deadlines,
  preserve simulation progress, and allow a replacement client to authenticate.
- On the fixed performance runner, panel request-to-native-commit p99 is below
  50 ms and native-commit-to-rendered-ACK p99 is below 50 ms. Measure the two
  legs separately from real authenticated traffic and the production panel
  update path; do not relabel WebSocket RTT or server queue time as rendered
  ACK latency.
- Authenticated-idle GSP versus disabled GSP changes the same physics tick
  timing metric by less than 1% across paired 60-second runs with identical
  workload, warm-up, build, and runner provenance. Report raw samples,
  aggregation, run order, and comparison; do not pass by shortening the
  acceptance run.
- Telemetry serialization remains outside `_physics_process` and is below the
  existing 0.5 ms/snapshot budget on the fixed runner. Report distribution
  evidence rather than only a single favorable sample.
- Focused reliability/performance stress is runnable through repository script
  patterns and the existing Linux native/build/headless/headed gate remains
  green.

## Queue/backpressure constraints

- Reuse `GspServer`, its reliable FIFO, and its depth-one latest telemetry
  slot. Do not add a second transport, recorder, telemetry producer, worker
  thread, or competing state authority.
- Keep reliable and lossy paths explicit. Reliable messages are never
  drop-oldest. Telemetry is latest-wins and may be suppressed/dropped.
- Check native buffered bytes before telemetry and reliable sends. Reliable
  traffic may continue below the hard-close threshold even while telemetry is
  suppressed; the hard threshold closes the peer deterministically.
- One slow peer must not block a healthy peer. Peer failure accounting and
  close state are per-peer; global counters may summarize but must not be the
  only evidence.
- Keep JSON serialization and socket flushing in non-physics processing. The
  physics loop may publish/copy its existing fixed telemetry snapshot and
  consume staged tuning only; it may not wait for WebSocket capacity, browser
  rendering, or performance instrumentation.
- Bound all test hooks and diagnostics. Prefer existing public diagnostics or
  test-only seams; do not expose production queue mutators or unbounded trace
  buffers.

## Performance and platform constraints

- Use the existing authoritative native commit result/tick for control timing
  and the production panel DOM/render path for display timing. Correlate
  samples by request/commit identity and exclude rejected/transient requests
  from successful-latency statistics.
- Do not weaken thresholds, discard slow samples, or silently retry failed
  measurements. Fail with a diagnostic report when the sample count,
  provenance, correlation, or timing clock is invalid.
- Use monotonic clocks for intervals. Wall-clock timestamps may appear only as
  report metadata.
- Preserve deterministic floating-point flags and existing Hardware
  configuration, telemetry snapshot, replay, preset, Quick Adjust, and
  external-authority paths.
- Do not add or reuse a GPU vendor/type/device/driver/renderer requirement for
  this issue. The reliability and physics-overhead gates must be behavior- and
  performance-based and GPU-neutral. Record observed hardware where available;
  do not create an allowlist. Do not broaden this task into the final Wayland
  qualification owned by issue #252.

## Required TDD evidence

1. RED/GREEN contract tests for all threshold/capacity invariants and for
   telemetry suppression below hard close.
2. Real authenticated slow-peer integration proving:
   - telemetry remains depth one and resumes with the newest sample;
   - reliable ACK reaches a healthy peer while another peer is suppressed or
     closed;
   - overflow attempts the bounded overflow error, records local outcome, and
     never claims delivery;
   - hard pressure closes/reclaims only the impaired peer;
   - stall/background/refresh/kill/replacement scenarios preserve physics and
     bounded peer counts.
3. A reproducible latency benchmark with enough correlated successful samples
   to report request→commit and commit→render p50/p95/p99, each p99 below
   50 ms.
4. A reproducible paired 60-second authenticated-idle-versus-disabled benchmark
   demonstrating less than 1% physics tick-time change, plus telemetry
   serialization distribution evidence below 0.5 ms/snapshot.
5. Run narrow tests first, then the exact full committed-HEAD gate:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-251 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

If the current environment cannot execute a required fixed-runner, headed
browser, or 60-second performance qualification, implement and test the
deterministic harness, run all available smoke/contract coverage, and report
the exact environment blocker without claiming that acceptance item passed.
Do not replace it with a weaker metric.

## Handoff

Write a detailed problem/solution/test report to `task-11-report.md`, including
raw performance artifact paths and any environment-deferred qualification.
Commit all task changes, remove only known generated Godot artifacts, and
leave the worktree clean. Do not edit the ledger or GitHub issue.
