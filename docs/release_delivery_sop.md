# Release Delivery SOP

Issue #52 tracks the full private delivery flow. This document is the current
operator checklist and evidence template. Items marked `not verified` require
device, GPU, signing, or customer-flow evidence before #52 can close.

## Automated Gates

Run these before preparing a delivery bundle:

```bash
scripts/test_license_scan.sh
python3 -m unittest license_server.test_license_server
```

`scripts/test_license_scan.sh` generates:

```text
build/THIRD_PARTY_NOTICES.txt
```

Release artifact size checks use:

```bash
scripts/export_linux_release.sh
scripts/export_windows_release.sh
scripts/export_android_release.sh
python3 scripts/check_release_artifacts.py \
  build/release/AeroSim-windows.zip \
  build/release/AeroSim-linux.zip \
  build/release/AeroSim-macos.zip \
  build/release/AeroSim-android.apk
```

Each artifact must be `<= 300 MB`.

## Artifact Checklist

| Artifact | Path | Gate | Current status |
| --- | --- | --- | --- |
| Windows desktop bundle | `build/release/AeroSim-windows.zip` | size <= 300 MB | CI verified |
| Linux desktop bundle | `build/release/AeroSim-linux.zip` | size <= 300 MB | CI verified |
| macOS desktop bundle | `build/release/AeroSim-macos.zip` | size <= 300 MB, signed/notarized if distributed outside a trusted channel | not verified |
| Android sideload APK | `build/release/AeroSim-android.apk` | size <= 300 MB, installs on device | CI export pending; device install not verified |
| Third-party notices | `build/THIRD_PARTY_NOTICES.txt` | generated from `third_party/licenses.json` | CI verified |

## Android Sideload

1. Transfer `build/release/AeroSim-android.apk` to the target device.
2. Enable install from unknown sources for the transfer app.
3. Install the APK.
4. Launch AeroSim and record cold-start time to first flyable screen.
5. Record device model, Android version, install result, and launch result.

The CI APK is signed with a generated test keystore at
`.deps/aerosim-ci-android.keystore` for artifact validation only. Production
delivery must replace it with the release keystore before sending the APK to a
customer.

This is `not verified` until performed on a real device.

## License Delivery Drill

Use the license server API documented in `docs/license_server.md`.

1. Start the license server with a secret from a secret store or root-only file.
2. Register the customer and store the returned license key in the customer record.
3. Send the customer the artifact bundle, install instructions, and license key.
4. On first launch, issue a token for the customer's device id.
5. Verify online activation.
6. Revoke the license key.
7. Confirm the next online verification fails as revoked.

The API behavior is covered by `license_server.test_license_server`; the
end-to-end customer delivery drill is `not verified` until performed with the
actual delivery channel.

## Evidence Template

| Gate | Evidence | Result |
| --- | --- | --- |
| G6.1/G6.2 artifact sizes | `scripts/check_release_artifacts.py` output | not verified |
| G6.2 Android sideload | device log / screen recording | not verified |
| G6.3 license scan + NOTICE | CI link + `build/THIRD_PARTY_NOTICES.txt` | not verified |
| G6.4 cold start | stopwatch/high-speed capture | not verified |
| G6.7 delivery drill | dated checklist + license server logs | not verified |
