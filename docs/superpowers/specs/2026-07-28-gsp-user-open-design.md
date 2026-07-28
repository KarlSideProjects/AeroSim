# GSP User-Initiated Panel Opening Design

## Goal

Make the Ground Station Panel reachable on GNOME Wayland without treating a
successful `OS.shell_open()` call as proof that a browser tab became visible.

## Scope

When GSP is enabled and its localhost server is ready, the existing pause
panel exposes two controls:

- `OPEN GSP PANEL` requests the browser through the existing launcher.
- `COPY GSP URL` puts the current, per-run panel URL on the clipboard for a
  manual paste into the browser address bar.

The controls are absent when GSP is disabled or unavailable. They are only a
paused/post-flight workstation entry point; they do not change flight controls,
Quick Adjust, telemetry, browser choice, or GPU support.

## Design

`GspLauncher` retains the authoritative runtime URL after starting the server.
It provides small public methods to report readiness, request a panel open, and
copy that URL. A browser-open request is best-effort because Wayland does not
permit an application to force another application to foreground.

`FlightRuntime` reads the sibling launcher while building the pause panel. If
ready, it creates the two buttons and a short status label. Button presses call
the launcher methods and update that label with either a success request notice
or a failure reason. The URL is never rendered in the HUD, because its fragment
contains the session token.

## Error Handling

If GSP is disabled, starts on X11, fails to bind, or cannot install its panel,
no controls appear. If opening fails, the status label tells the user to use
`COPY GSP URL`; copying is only enabled while a current URL exists.

## Tests

Extend the launcher contract with readiness, user-open, and clipboard-eligible
state tests. Extend the existing HUD/pause-panel coverage to verify that GSP
controls appear only for a ready launcher and that their button handlers call
the launcher. Run the focused tests and `git diff --check`.
