# Task 11 — GitHub issue #251 report

## Current protocol revision

The current code-bearing protocol revision is `dfa6d1c` (after `8976dfb` real-time timing and `95796bb` Processor cooling evidence). It adds sysfs CPPC `feedback_ctrs`/`reference_perf` parsing, `P(a,b)` window checks, resolved Processor cooling-device IDs, monotonic cooling/state/transition checks, phase-boundary snapshots, D_a/D_b CPPC/Tctl drift, exact CPU configuration provenance, and explicit `PASS`/`FAIL`/`UNAVAILABLE` with `failure_kind`.

No formal conditioning or D-I-I-D qualification was run from `dfa6d1c`. The directories below are explicitly aborted pre-protocol attempts: each contains only `conditioning.godot.log`, has no valid raw artifact, and must not be counted as conditioning or qualification evidence.

- `build/gsp-idle-qualification-8976dfb/` — aborted immediately after start by Ctrl-C; pre-Processor-cooling protocol.
- `build/gsp-idle-qualification-95796bb/` — aborted immediately after start by Ctrl-C; pre-CPPC/final protocol.

## Problems and solutions

- Reliable application admission now bounds application message count, application bytes, and message size independently. Native buffered bytes are sampled only by transport flush policy, so a native queue sample cannot consume application FIFO budget.
- Reliable flush remains FIFO and peeks the head. It removes and decrements only after `send_text == OK`; send failure leaves the head. Telemetry is latest-wins, depth one, reliable-first, and suppressed below the reachable native hard-close policy.
- Overflow is persistent and overflow-specific. Earlier accepted reliable messages drain first; the closing pump makes one nonrecursive best-effort overflow-envelope attempt, records attempted/local acceptance separately, never claims delivery, then closes. Ordinary send failure and inbound packet-count overload do not emit overflow.
- Tuning preflight uses the central admission helper. Hard pressure closes only the affected peer. Existing focused evidence preserves FIFO, peer-local isolation, replacement/reclaim, deterministic flags, replay, and security behavior.
- Panel timing uses monotonic clock synchronization and authoritative native commit identity. The production DOM update is followed by double-RAF rendered observation. The existing headed Chrome artifact has 100 correlated samples and is vendor-neutral evidence; GPU identity is metadata only.
- The paired performance runner was replaced with a frozen four-process external-client design. Each authenticated-idle process starts the real `GspServer`, publishes ready `{port, token}` metadata, and is driven by the repository's stdlib WebSocket helper. The external client authenticates, sends only `set_telemetry hz:30`, and continuously drains until process shutdown. Disabled processes start no server or client.

## TDD and focused tests

RED:

```text
python3 -m unittest tests/test_gsp_issue251_protocol.py tests/test_gsp_issue251_contract.py
```

The initial run failed because the old runner had same-process `paired` mode, no ready metadata/external client, and no frozen per-run signed comparison. GREEN passed after replacing that design.

Focused GREEN evidence for the current revision:

```text
python3 -m unittest tests/test_gsp_issue251_protocol.py tests/test_gsp_issue251_contract.py  # 7 tests PASS
python3 -m py_compile scripts/run_gsp_idle_benchmark.py              # PASS
python3 scripts/test_gsp_idle_benchmark_smoke.py                     # PASS, real authenticated lifecycle
python3 scripts/test_gsp_transport.py                                # PASS, 1000 samples, p99 0.119 ms
Godot gsp_transport_contract.gd                                      # PASS
Godot gsp_transport_integration.gd                                   # PASS
Godot gsp_telemetry_contract.gd                                     # PASS
python3 scripts/test_gsp_transport_boundary.py                       # PASS
  slow-peer overflow, packet rejection, suppression/isolation,
  replacement/reclaim, restart-token, FIFO/overflow boundaries
external authenticated-idle benchmark smoke                         # PASS
  ready/auth/drain lifecycle, open samples, telemetry received
```

`gsp_telemetry_integration.gd` was also run and failed its existing paused-restore assertion (`paused restore succeeds without a new source sample`). This issue changes only the performance benchmark and external runner; the telemetry contract and all boundary/transport focused tests passed. The failure is reported, not hidden.

## Historical qualification design and result

Historical code-bearing HEAD: `328e9e356647cb75252d8fc50c364671af2f95b8`.

The only fresh qualification was run once from a new output directory with this fixed order:

```text
D_a, I_a, I_b, D_b
```

Every run was a fresh Godot process with the production `EffectWorkload` on the production SmokeScene, 10 seconds warmup, 60 seconds measurement, and exactly 14,400 retained `PhysicsFrameProfiler._tick` samples. The primary metric was frozen before the run:

```text
pair_a = (mean(I_a) - mean(D_a)) / mean(D_a)
pair_b = (mean(I_b) - mean(D_b)) / mean(D_b)
aggregate = (pair_a + pair_b) / 2
```

Both individual signed pair percentages and the aggregate must have absolute value `<1%`. Percentiles are diagnostics only; no samples were dropped and no frame-index pairs were treated as independent experiments.

Result: **INVALID DURATION**, retained as invalid-duration evidence, not a performance FAIL. The runner passed `--fixed-fps 240`; artifact mtime showed only 5.4–6.4 wall seconds for the nominal 70-second runs, with 187–189 telemetry frames. It cannot establish the AC and was not reused.

```text
D_a mean 0.1400449306 ms, p50 0.097 ms, p95 0.291 ms, p99 0.312 ms
I_a mean 0.1496139583 ms, p50 0.108 ms, p95 0.302 ms, p99 0.321 ms
I_b mean 0.1467845833 ms, p50 0.105 ms, p95 0.297 ms, p99 0.317 ms
D_b mean 0.1460110417 ms, p50 0.103 ms, p95 0.296 ms, p99 0.316 ms

(I_a-D_a)/D_a = +6.8328269648%
(I_b-D_b)/D_b = +0.5297829930%
aggregate       = +3.6813049789%
```

The concrete blocker is process/runtime interference: the second disabled run itself rose from `0.1400449306 ms` to `0.1460110417 ms`, while both authenticated runs remained fully healthy. This fresh-process design therefore does not establish the required `<1%` performance AC on this host; the result is not a PASS claim.

The authenticated lifecycle evidence was valid in both idle runs: each had `16,800/16,800` open samples, no suppression, no overflow, no hard close, `187–188` server telemetry sends, and `187–189` externally drained telemetry frames. Serialization distributions were retained; observed p99 wire serialization was `94 us` and `119 us`, below `0.5 ms`.

## Pilot evidence deliberately excluded

- `build/gsp-idle-benchmark-final3/`: old independent-process pilot from commit `a85323f`; it passed the superseded all-metrics calculation and is not qualification evidence.
- `build/gsp-idle-benchmark-final4/`: old independent-process pilot from commit `3870388`; it failed the superseded all-metrics calculation (`mean +1.346645%`, `p99 +2.39617%`) and is not qualification evidence.
- `build/gsp-idle-qualification/`: same-process AB/BA experiment from `0b4b718`; it showed phase drift and is not qualification evidence.
- `build/gsp-idle-qualification-8976dfb/`: aborted pre-protocol attempt from `8976dfb`; only `conditioning.godot.log` exists.
- `build/gsp-idle-qualification-95796bb/`: aborted pre-protocol attempt from `95796bb`; only `conditioning.godot.log` exists.

These artifacts remain useful noise/root-cause evidence only. None was reused or selectively reclassified as the final result.

## Artifact paths

- Final raw qualification: `build/gsp-idle-qualification-328e9e3/comparison.json`
- Final physics raw runs: `build/gsp-idle-qualification-328e9e3/{D_a,I_a,I_b,D_b}.raw.json`
- Final external-client lifecycle raw runs: `build/gsp-idle-qualification-328e9e3/{D_a,I_a,I_b,D_b}.external.raw.json`
- Final Godot logs: `build/gsp-idle-qualification-328e9e3/{D_a,I_a,I_b,D_b}.godot.log`
- Browser production artifact retained from the unrelated panel timing implementation: `build/gsp-browser/performance.raw.json`
  - Chrome headed CDP, 100 sequential correlated samples
  - request→native commit p99 `35.585 ms`
  - native commit→double-RAF rendered p99 `38.946 ms`
  - monotonic clock sync: 8 samples, best RTT `4.800 ms`, error bound `2.400 ms`
- Slow-peer boundary artifact: `build/gsp-boundary-251-final.log`
- Full gate generated evidence: `build/native_debug_artifact.json`, `build/gut/junit.xml`, `build/headless_smoke.json`

## Exact full gate

Command run once after code-bearing commit `328e9e3`:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-251 GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh
```

The wrapper result was `exit_code=0`; the captured output reached the final headless smoke and reported native probe `47`, `5` simulated frames, native/license/build checks, GSP boundary, headed acceptance, replay, GUT `277/277`, and all visible sub-gates passed. This was the prior gate, not a gate for current `dfa6d1c`.

## Deferred or blocked items

- The current CPPC/cooling-qualified `<1%` physics-overhead acceptance remains **not run** pending explicit authorization after `dfa6d1c`; no PASS or FAIL is claimed.
- The paused-source-sample telemetry integration failure remains a focused-test blocker unrelated to this benchmark change and is recorded above.
- No GPU vendor/type/device/driver/renderer allowlist was added. The frozen NVIDIA-specific G0.1 qualification was not used as proof for #251.
- Codebase-memory MCP was available, the worktree index was ready, and it was used first for transport/telemetry/benchmark discovery. The issue ledger, GitHub, and #252 were not edited.
