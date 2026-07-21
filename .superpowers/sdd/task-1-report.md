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
