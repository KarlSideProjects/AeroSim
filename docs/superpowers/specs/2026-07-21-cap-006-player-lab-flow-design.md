# CAP-006 Player/Lab Flow Design

## Goal

Implement issue #43 as one Ubuntu Player/Lab flow: seven main-menu entries, a single session-only Flight Setup panel, safe Quick Fly license gating, and Lab Mode using the existing game session.

## Fixed boundaries

- Main menu order is `Quick Fly`, `Lab Mode`, `Controller`, `Drone`, `Map`, `Settings`, `Quit`.
- `Drone` and `Map` open the same Flight Setup panel, with the originating entry as its initial focus. The panel owns one in-memory selection object for drone, map (`industrial_yard`, displayed as Industrial Test Range), mode, and wind preset. It creates no settings file and persists nothing. The prior Map-only rain, fog, and time controls are removed from this flow; they are not copied into a second panel.
- Apply is explicit: a Flight Setup `Fly` action validates the four allowed selection values, applies them through the existing hardware/map/wind runtime paths, then enters preflight. `Quick Fly` explicitly restores those same runtime paths to their existing defaults before preflight; it never reuses a prior Flight Setup choice or displays the panel.
- `Lab Mode` changes the existing status dashboard from compact to full layout. Its return action restores the Player/main-menu presentation; it does not create another scene, native runtime, AirSim session, or RPC server.
- `Controller` stores a session-only return target. Confirmation, keyboard fallback, and cancellation return to that target when launched from Controller; the Quick Fly path alone continues confirmation or fallback to preflight.
- `Quit` calls the existing runtime exit path so cleanup runs.

## License gate

FlightRuntime creates and configures the existing `LicenseProvider` once at startup from the shipped provider configuration. FlightRuntime owns only the provider's public `activate`, `refresh_online`, and sanitized `get_snapshot` calls; no provider state is copied to SettingsStore or another model.

- Missing provider/config/public key or configuration failure is a named terminal error; Quick Fly is unavailable.
- `online_valid` and `offline_grace_valid` may proceed.
- `not_activated` provides non-persistent license-key activation plus Diagnostics and Exit; it does not pretend Retry can activate a missing license.
- `offline_grace_expired`, `revoked`, and `invalid_token` provide Retry, Diagnostics, and Exit. Retry only calls `refresh_online` where the provider permits it; expiry does not silently extend offline grace.
- No JWT, license key, customer data, or raw claims are copied into SettingsStore, UI state, logs, or tests. The activation field is cleared after its request completes.

## Testing and evidence

GUT and headless smoke cover seven ordered interactive entries, shared Drone/Map setup, Quick Fly default reset, Lab session reuse, controller return behavior, quit cleanup route, and loud license-provider setup failure. Existing headed smoke supplies non-human provisional evidence; no human visual review is requested until CAP-006 passes.

## Non-goals

No new settings schema/store, license persistence, second map selector, second dashboard/session, environmental dashboard controls, or PRD decision changes.
