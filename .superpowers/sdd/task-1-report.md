# Task 1 Report: Wire the Existing License Provider

Date: 2026-07-21

Status: DONE. Task 2 was not started. No GitHub comment was posted. The frozen #131 decision was followed; no PRD or product decision changed.

## Delivered

- `FlightRuntime` owns one existing `LicenseProvider` and delegates through its public `configure_from_path`, `configure`, `activate`, `refresh_online`, and `get_snapshot` methods. It stores no provider state, JWT, claims, key, persistence, or secrets.
- Startup builds the menu and HUD before provider configuration. Missing, invalid, or rejected configuration enters the named `license_blocked` screen with an observable blocked panel and only Exit available. Status UI uses sanitized snapshot data.
- Quick Fly starts only for sanitized `online_valid` and `offline_grace_valid` snapshots.
- Public runtime routes are `get_license_snapshot`, `can_start_quick_fly`, `license_actions`, `activate_license`, and `retry_license`.
- `activate_license` guards the sanitized status before reading the input or calling the provider. It permits only `not_activated`, `offline_grace_expired`, and nonfatal `invalid_token`; all other statuses return `activation_unavailable` without a provider call, while fatal/absent configuration returns a fatal result. After awaited activation, it clears the real transient secret `LineEdit`, re-reads the sanitized snapshot, and either clears the error/show-main-menu on valid status or remains blocked and refreshes the panel.
- Retry follows frozen #131: expired/nonfatal invalid-token statuses reuse activation and require a newly entered nonpersistent key; revoked calls `refresh_online`; not-activated rejects Retry; fatal/absent states make no provider request. After revoked refresh, the runtime re-reads the snapshot and transitions or remains blocked accordingly.
- The key field is visible only for activation-backed statuses and is cleared when the status/screen is non-key. A Diagnostics button is visible only when `license_actions()` includes `diagnostics`; it clears the transient field and calls existing `show_settings()`, reusing SettingsPanel, Settings Status, and `last_error_message`. No diagnostics scene/module or support-bundle integration was added.
- Tests use the real provider for missing configuration/public-key startup behavior and the existing counter-based fake for status dispatch. No key literal is used and the fake does not retain a key.

## Root causes addressed

The first implementation wired the provider but had three boundary gaps: assigning an empty local activation parameter did not clear UI input; configuration failure could happen before the UI existed; and retry/activation routes were not constrained by the provider's sanitized state. Provider inspection also confirmed that unauthorized handling clears its cached JWT, making a follow-up refresh ineffective. The runtime now treats those states explicitly and reconciles UI/startup state after awaited provider actions.

## TDD evidence

1. Initial Task 1 RED/GREEN established the provider seam, blocked screen, Quick Fly gate, and status actions.
2. Adversarial-fix RED/GREEN covered the real transient input, missing config/public key UI, exact retry table, fatal/absent snapshots, and no key retention.
3. This follow-up RED: the new transition, visibility/clearing, diagnostics, and direct-activation-guard tests failed before implementation (171 total tests with four new behavior failures, alongside the expected recovery pending tests).
4. GREEN: after minimal implementation and a test-path correction, all Task 1 behavior tests pass, including activation/refresh transitions, key visibility and clearing, diagnostics reuse, and status guards.

## Validation

| Command | Result |
| --- | --- |
| `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode` | PASS; 171 tests, 0 failures, 0 errors; 11 expected native-unavailable pending tests. |
| `git diff --check` | PASS. |

## Concerns

Recovery mode intentionally leaves 11 native-dependent tests pending. GUT reports one existing unfreed-child warning from the license-provider test suite; it is not a failure. No blocker remains.
