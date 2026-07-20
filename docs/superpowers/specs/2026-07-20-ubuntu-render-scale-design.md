# Ubuntu 3D Render Scale Design

## Goal

Add the one quality setting required by #135: a persistent 3D render scale for
Ubuntu. It improves the playable build without creating a renderer-options
matrix.

## Scope

The `quality` settings domain owns exactly this schema:

```json
{
  "schema_version": 1,
  "render_scale": 1.0
}
```

`render_scale` is a finite number from 0.50 through 1.00 inclusive in 0.05
steps. Unknown, missing, non-finite, out-of-range, and off-step values fail
loudly through the existing `SettingsStore` recovery contract. A missing
`quality` domain uses the factory default 1.00.

## Runtime and UI

`FlightRuntime` keeps the active render scale as a domain value. Startup reads
the persisted `quality` snapshot and immediately applies it to the root
viewport with `Viewport.scaling_3d_scale`. Factory reset restores 1.00 and
applies it immediately.

Settings gains a `GRAPHICS` entry and a focused graphics panel. It contains
one `3D RENDER SCALE` HSlider (50% to 100%, 5% steps), a current-percent label,
`APPLY`, `RESET DEFAULTS`, and `BACK`. Slider changes update the root viewport
immediately without reloading a scene. `APPLY` is the only persistence action;
this supports mouse, keyboard, and gamepad focus navigation without writing on
every slider frame. The 2D UI stays at native resolution because only the
viewport 3D scale changes.

## Boundaries

Reuse the existing SettingsStore envelope and atomic save path. Do not add a
second store, renderer configuration, dynamic resolution, FSR, anti-aliasing,
shadow, fog, or platform-specific settings.

## Verification

GUT covers the exact quality schema, all accepted endpoints, invalid values,
startup restoration, immediate viewport application, explicit save, and factory
reset. Existing full GUT, native, headless, and headed checks remain required.
