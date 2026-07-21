# CAP-006 Player/Lab Flow Design

## Goal

Implement issue #43 as one Ubuntu Player/Lab flow: seven main-menu entries, a single session-only Flight Setup panel, safe Quick Fly license gating, and Lab Mode using the existing game session.

## Fixed boundaries

- Main menu order is `Quick Fly`, `Lab Mode`, `Controller`, `Drone`, `Map`, `Settings`, `Quit`.
- `Drone` and `Map` open the same Flight Setup panel. The panel owns one in-memory selection object for drone, the sole Industrial Test Range map, mode, and wind preset. It creates no settings file and persists nothing.
- `Quick Fly` resets those selections to the existing defaults before entering preflight; it never reuses a prior Flight Setup choice or displays the panel.
- `Lab Mode` changes the existing runtime/dashboard presentation only. It does not create another scene, native runtime, AirSim session, or RPC server.
- `Controller` remains a standalone mapping path. Confirmation reached from Controller returns to its caller; confirmation reached from Quick Fly continues to preflight. Existing keyboard fallback remains available.
- `Quit` calls the existing runtime exit path so cleanup runs.

## License gate

FlightRuntime creates and configures the existing `LicenseProvider` once at startup from the shipped provider configuration. The runtime reads only its sanitized snapshot.

- Missing provider/config/public key or configuration failure is a named terminal error; Quick Fly is unavailable.
- `online_valid` and `offline_grace_valid` may proceed.
- `not_activated`, `offline_grace_expired`, `revoked`, and `invalid_token` show a blocking screen with Retry, Diagnostics, and Exit. No JWT, license key, customer data, or raw claims are copied into runtime state, SettingsStore, UI, logs, or tests.

## Testing and evidence

GUT and headless smoke cover seven ordered interactive entries, shared Drone/Map setup, Quick Fly default reset, Lab session reuse, controller return behavior, quit cleanup route, and loud license-provider setup failure. Existing headed smoke supplies non-human provisional evidence; no human visual review is requested until CAP-006 passes.

## Non-goals

No new settings schema/store, license persistence, second map selector, second dashboard/session, environmental dashboard controls, or PRD decision changes.
