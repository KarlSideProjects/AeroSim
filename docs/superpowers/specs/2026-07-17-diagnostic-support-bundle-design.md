# Ubuntu Diagnostic Support Bundle

## Goal

Export one sanitized `support.json` inside a ZIP for Ubuntu support triage.

## Design

`DiagnosticSupportBundle` is an isolated `RefCounted` module. Callers pass only already-sanitized metadata, license snapshot, controller mapping, last-error code, and raw input samples. The module never opens the network, reads `user://`, collects logs, or changes `flight_runtime.gd`.

The output is a fixed allowlist with typed fields for build/app/platform/GPU, controller state and mapping, license state, named error code, named events, and relative-time raw samples. Events are capped at 200 and 600 seconds; samples are capped at 150 and five seconds at export.

Export serializes one JSON file, rejects unknown keys/types, secret/PII canaries, and JSON size above 256 KiB, then writes and audits a temporary ZIP before atomic rename. Any failure removes temporary output and leaves no destination ZIP.

## Verification

Focused GUT tests exercise the public capture, build, audit, and export interfaces, including negative security cases and archive cleanup. Documentation records the schema and the explicit non-goal that #131 DEV-M human validation remains outstanding.
