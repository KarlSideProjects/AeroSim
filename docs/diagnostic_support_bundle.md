# Ubuntu diagnostic support bundle

`DiagnosticSupportBundle` exports exactly one ZIP member, `support.json`. The checked-in contract is [config/diagnostic_support_schema.json](../config/diagnostic_support_schema.json).

The module is deliberately local-only. The caller supplies already-sanitized build/platform/GPU metadata, the `LicenseProvider.get_snapshot()` status and offline-grace remaining seconds, the confirmed `GamepadProfile.to_persisted_dict()` mapping, USB IDs, and a named last-error code. It does not make HTTP requests, read `user://`, collect logs, or inspect process/environment data. An unreachable license server therefore only affects the supplied local snapshot.

Events are named codes from the most recent 600 seconds, capped at 200. Raw roll/pitch/yaw/throttle plus Arm/Mode samples are supplied at the 30 Hz capture boundary, exported from the preceding five seconds, capped at 150, and timestamped only by relative seconds from export.

Before atomic rename, the exporter rejects unknown keys/types, secret or PII canaries, malformed schema, and JSON larger than 256 KiB. It writes a temporary ZIP, verifies that it contains only `support.json`, parses and re-audits the member, then renames it atomically. Every failure removes the current temporary file; an existing completed bundle is left intact.

The module is not wired into `flight_runtime.gd` or a Settings UI in #51. That keeps #146 Dataset Recording and the shared flight runtime out of scope. #131's DEV-M human validation of the Ubuntu license client remains an explicitly incomplete gate; this issue does not mark it complete or close it.
