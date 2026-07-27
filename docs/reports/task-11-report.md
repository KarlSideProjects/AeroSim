# Task 11 — GitHub issue #251 report

## Outcome

Issue #251 code and review were complete before the formal performance run. Sol-high's code-quality review was PASS. The one frozen formal qualification then ran exactly once from commit `73101915510e5517bd90f40c24543ec63b226888` and stopped at conditioning:

- status: **FAIL**
- failure kind: `conditioning_sample_count`
- required conditioning samples: `72000`
- observed conditioning samples: `43479`
- measurement elapsed: `299.997691 s` (within the required `299.5–300.5 s` interval)
- runner exit code: `1`
- D-I-D was not started; no comparison was produced
- no qualification rerun was performed

The required `<1%` performance AC therefore remains not passed. This result is a protocol failure, not a GPU qualification result.

## Implementation

The final code path is GPU vendor/type/device/driver/renderer neutral and preserves the issue-251 transport and telemetry guarantees: bounded application reliable admission, reliable FIFO, send-failure head retention, depth-one latest-wins telemetry, peer-local hard pressure, overflow-specific closing behavior, authoritative commit, replay, security, and deterministic flags.

The benchmark protocol uses real-time fresh Godot processes, production physics workload, external authenticated idle clients, CPPC package aggregate performance, cooling-state evidence, configuration provenance, monotonic timing, and fixed D-I-D ordering. GPU metadata is recorded only. The latest code closure commit is `d1554c2` (`Fix #251 conditioning failure evidence`), which writes `qualification.failure.json` before re-raising the sample-count error; it does not convert the error to `UNAVAILABLE` or catch unrelated runtime errors.

The frozen primary qualification metric was:

```text
pair_a = (mean(I_a) - mean(D_a)) / mean(D_a)
pair_b = (mean(I_b) - mean(D_b)) / mean(D_b)
aggregate = (pair_a + pair_b) / 2
```

No D-I-D pair exists for the formal run, so no performance comparison or `<1%` PASS is claimed.

## Formal artifacts and immutable hashes

The original artifacts were retained unchanged:

- raw: `build/gsp-idle-qualification-7310191/conditioning.raw.json` — SHA256 `9bfc68375666ffa85519551e215e21759f05073f94c44ba8a68f0de1744dd13d`
- environment: `build/gsp-idle-qualification-7310191/conditioning.environment.raw.json` — SHA256 `aff8f6a1ca8fb32ecf91859ca339c81070365a9793003d3c4db59938972ab45f`
- log: `build/gsp-idle-qualification-7310191/conditioning.godot.log` — SHA256 `a550f99a4dd71541e54c99276e839876cae14f59fd6704c91070f4c64274db43`

The closure artifact is derived from that existing raw only:

- `build/gsp-idle-qualification-7310191/qualification.failure.json`
  - `artifact_origin`: `posthoc-derived-from-existing-raw`
  - `runner_exit_code`: `1`
  - `failure_kind`: `conditioning_sample_count`

There is deliberately no comparison artifact and no replacement or selected run.

## Browser and serialization evidence

The headed Chrome production-browser runner completed 100 sequential monotonic correlated samples. Reported diagnostic p99 values were:

- panel request → authoritative native commit: `35.585 ms`
- native commit → post-DOM-update double-RAF rendered acknowledgement: `38.946 ms`

Telemetry wire serialization remained within its `<0.5 ms` budget, including JSON serialization; observed p99 distributions were `94 us` and `119 us` in the retained focused evidence.

## Historical and rejected evidence

- `build/gsp-idle-qualification-328e9e3/` is **INVALID DURATION**, not a performance FAIL: `--fixed-fps 240` disabled real-time synchronization, so nominal 60-second runs lasted about 5.4–6.4 wall seconds and received only about 187–189 telemetry frames. It was not reused.
- `build/gsp-idle-qualification-8976dfb/` is an aborted pre-protocol attempt; only `conditioning.godot.log` exists.
- `build/gsp-idle-qualification-95796bb/` is an aborted pre-protocol attempt; only `conditioning.godot.log` exists.
- Pilot artifacts `final3`, `final4`, and the earlier same-process qualification were excluded. No post-hoc sample-count, statistic, pair, or run selection was performed.

## Verification and gate provenance

Focused transport, telemetry, protocol, provenance, cooling, CPPC, overflow, browser-contract, and benchmark tests were run during implementation. The final focused suite and real authenticated smoke were run after the closure fix:

```text
python3 -m unittest tests/test_gsp_issue251_protocol.py tests/test_gsp_issue251_contract.py
python3 scripts/test_gsp_idle_benchmark_smoke.py
git diff --check
```

All completed successfully. The exact full committed-HEAD gate at `7310191` returned exit code `0`; it is recorded here as prior evidence and was not rerun after the report/closure-only changes.

GPU provenance recorded the actual `card0` AMD and `card1` NVIDIA devices. No GPU value gates the result, no vendor/type allowlist exists, and the frozen NVIDIA-specific G0.1 qualification was not invoked as proof for issue #251.

The issue ledger and GitHub were not edited; issue #252 was not touched.
