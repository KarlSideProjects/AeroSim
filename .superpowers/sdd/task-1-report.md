# Task 1 Report: Wire the Existing License Provider

Status: DONE

## Delivered

- `FlightRuntime` now preloads and owns one `LicenseProvider`, configuring it once during startup from `res://config/license_provider.json` through the provider's public `configure` method.
- Missing, invalid, or rejected provider configuration enters the named `license_blocked` screen and prevents Quick Fly from requesting takeoff.
- Quick Fly is allowed only for sanitized provider snapshots with `online_valid` or `offline_grace_valid` status.
- Added the public runtime seam used by later menu work: `get_license_snapshot`, `can_start_quick_fly`, `license_actions`, `activate_license`, and `retry_license`.
- `not_activated` exposes activation, Diagnostics, and Exit actions; `offline_grace_expired`, `revoked`, and `invalid_token` expose retry, Diagnostics, and Exit. Retry does not call the provider for `not_activated`.
- Activation awaits the provider request and clears the entered key parameter afterward. No JWT, claims, license key, or copied provider state is stored in runtime settings/UI state.

## Root Cause and Solution

The existing provider was tested in isolation but was not connected to `FlightRuntime`; Quick Fly therefore had no license decision boundary. The runtime now reads the provider's sanitized `get_snapshot()` result at the Quick Fly seam and delegates activation/refresh directly to the existing provider methods.

## TDD Evidence

1. RED: the specified tests failed with nonexistent `_configure_license_provider`, `license_provider`, and `can_start_quick_fly` runtime APIs.
2. GREEN: the provider boundary implementation made both specified tests pass.
3. RED: the added public-route test failed because `license_actions` was absent.
4. GREEN: the route implementation made activation and status-specific retry behavior pass.

## Validation

| Command | Result |
| --- | --- |
| `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode` | PASS; 163 tests, 0 failures, 0 errors; 11 expected native-unavailable pending tests. |
| `git diff --check` | PASS. |

## Concerns

- The recovery-mode GUT command intentionally marks native-dependent tests pending; this task's license/runtime tests pass. No product decision was changed and no blocker remains.

# Task 1 Adversarial Fix Report

Date: 2026-07-21

Status: FIXED. Task 2 was not started. This fix follows the frozen #131 decision supplied by Sol; no PRD or product decision was changed.

## Review findings and root causes

- The original activation code assigned an empty string to a local parameter after awaiting the provider. That did not clear any user-visible input and could falsely imply key retention was handled.
- Provider configuration ran before menu/HUD construction, so a missing config or public key could stop startup without leaving an observable blocked UI state.
- `LicenseProvider.refresh_online()` requires a cached JWT. Its unauthorized response clears that JWT and leaves the provider in `invalid_token`; a subsequent refresh therefore returns `not_activated` without a meaningful online attempt. Treating every retryable-looking status as refresh would create an ineffective loop.

## Fix delivered

- `FlightRuntime` still owns exactly one existing `LicenseProvider` and uses its public `configure_from_path`, `configure`, `activate`, `refresh_online`, and `get_snapshot` methods. No second runtime, persistence, secrets, or copied provider state was added.
- Startup builds the menu and HUD before provider configuration. Missing, invalid, or rejected configuration enters `license_blocked`, renders an observable blocked panel, and exposes only `Exit`. The panel renders sanitized status text and never renders provider secrets.
- Added the smallest real transient activation route: a secret `LineEdit` with Activate/Retry/Exit controls. `activate_license` reads the field when invoked by the UI, awaits the provider activation, and clears that actual field afterward. No license-key literal or stored key is used by the tests or fake provider.
- Retry routing follows frozen #131 exactly: `offline_grace_expired` and nonfatal `invalid_token` call `activate_license` and require a newly entered field value; `revoked` calls `refresh_online`; `not_activated` rejects Retry; fatal and absent-provider snapshots return a fatal result without a provider request. Existing visible action labels remain represented by the exact action arrays.
- The status table covers `online_valid`, `offline_grace_valid`, `offline_grace_expired`, `invalid_token`, `revoked`, and `not_activated`, plus fatal public-key configuration and absent-provider snapshots. Dispatch assertions use the existing fake provider counters; configuration/UI tests use the real provider behavior.

## TDD and validation evidence

1. RED: the adversarial behavior tests initially failed on the missing real input route, blocked startup UI, and status-specific retry dispatch.
2. GREEN: after the minimal runtime/test changes, the exact recovery-mode GUT command passed with no Godot ERROR output.
3. `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode` — PASS; 167 tests, 0 failures, 0 errors, 11 expected native-unavailable pending tests.
4. `git diff --check` — PASS.

## Self-review and concerns

The provider is configured through its public API, status decisions read sanitized snapshots, activation has no runtime key storage, and fatal/absent retry paths perform no provider request. Recovery mode intentionally leaves the existing 11 native-dependent tests pending. No blocker remains; no GitHub comment was posted.
