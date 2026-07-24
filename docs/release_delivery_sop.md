# Release Delivery SOP

Issue #52 tracks the Windows/Linux private delivery flow. Android delivery is
deferred for the current release and its steps remain only as a future lane. macOS is
tracked separately by #93 and remains blocked by the Apple build environment
in #92. This document is the current operator checklist and evidence template.
Items marked `not verified` require device, GPU, signing, or customer-flow
evidence before #52 can close.

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
DISPLAY=:0 scripts/measure_linux_cold_start.sh
python3 scripts/check_release_artifacts.py \
  build/release/AeroSim-windows.zip \
  build/release/AeroSim-linux.zip
```

Each artifact must be `<= 300 MB`. `measure_linux_cold_start.sh` launches the
Linux release on a real local display, rejects an active Xvfb process, waits
for `frame_post_draw`, saves a non-monochrome screenshot beside
`build/cold_start/linux.json`, and keeps the window visible for three seconds.
It fails above the frozen 15-second G6.4 desktop threshold.

## Artifact Checklist

| Artifact | Path | Gate | Current status |
| --- | --- | --- | --- |
| Windows desktop bundle | future platform export artifact | size <= 300 MB | build-only lane; not verified by current Linux CI |
| Linux desktop bundle | `build/release/AeroSim-linux.zip` | size <= 300 MB | CI verified when the Linux workflow run is green |
| Android sideload APK | future platform export artifact | size <= 300 MB, locked production signature | deferred; not part of current release acceptance |
| Third-party notices | `build/THIRD_PARTY_NOTICES.txt` | generated from `third_party/licenses.json` | CI verified |

macOS packaging, Developer ID signing, notarization, and macOS cold-start
evidence are intentionally excluded from #52. They are acceptance work for
#93 after #92 provides the Apple build environment; this is a lane split, not
a change to the frozen G6.1 macOS threshold.

## Future Android Sideload Lane

This section is retained for a future Android lane. The current release does
not require an Android APK, production signing, or device sideload evidence.
When that lane is explicitly reopened, only download `release-android/AeroSim-android.apk` and
`release-android/signing.txt` from a **successful `push` to `main`** CI run.
Before any customer transfer, verify the run SHA is the intended `main` commit,
then run `apksigner verify --print-certs` on the downloaded APK and confirm its
SHA-256 signer fingerprint exactly matches `signing.txt`. CI itself rejects a
production APK unless that fingerprint matches the maintainer-frozen repository
variable `ANDROID_RELEASE_CERT_SHA256`.

1. Transfer that verified `release-android/AeroSim-android.apk` to the target device.
2. Enable install from unknown sources for the transfer app.
3. Install the APK.
4. Launch AeroSim and record cold-start time to first flyable screen.
5. Record device model, Android version, install result, and launch result.

Pull request CI APKs are signed with a generated test keystore at the job-local
`$RUNNER_TEMP/aerosim-tools-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$GITHUB_JOB/aerosim-ci-android.keystore`
path, or the explicit `AEROSIM_ANDROID_CI_KEYSTORE` path, for artifact
validation only. Production delivery must replace it with the release keystore
before sending the APK to a customer. CI stores this test-signed artifact as
`ci-android-apk` under the self-hosted runner Local Folder artifact root, not as a
customer-ready release artifact and **must never be delivered to a customer**.
When the Android lane is explicitly reopened, CI decodes the repository
production signing secret only into a job-local keystore, exports
`release-android/AeroSim-android.apk`, and publishes its public certificate
fingerprint as `release-android/signing.txt`. The keystore and passwords are
never stored in the repository or artifact folder. A missing or mismatched
`ANDROID_RELEASE_CERT_SHA256` fails the production signing step loudly.

Under `docs/decisions/2026-07-11-linux-primary-acceptance.md`, real-device
sideload is **N/A (unverified frozen), not pass** in the current environment.
Keep these steps for a future Android-device lane; they do not block Linux
acceptance.

## License Delivery Drill

Use the license server API documented in `docs/license_server.md`. The local
rehearsal command exercises registration, activation, revocation, and the
required post-revocation rejection against a real temporary localhost server:

```bash
scripts/exercise_delivery_drill.sh \
  --customer-id CUSTOMER-ID \
  --device-id CUSTOMER-DEVICE-ID \
  --artifact build/release/AeroSim-linux.zip
```

It records the artifact SHA-256 and step outcomes in
`build/delivery_drill/report.json`, without writing a license key or JWT. It
does not send an artifact or key through an external customer channel, so it
does not replace the DEV-M G6.7 delivery acceptance.

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
| G6.1 Linux release artifact size | `scripts/check_release_artifacts.py` output | CI verified when the Linux workflow run is green |
| G6.1 Windows artifact size | Platform build/export evidence | N/A (build-only lane; not verified by current Linux CI) |
| G6.2 Android artifact size / sideload | Platform build/export evidence and device log | Deferred for current release; not run, not pass, not a Linux blocker |
| G6.3 license scan + NOTICE | CI link + `build/THIRD_PARTY_NOTICES.txt` | CI verified |
| G6.4 Linux cold start | `build/cold_start/linux.json` from real-display release probe | automation added; not verified until measured release evidence exists |
| G6.7 delivery drill | `build/delivery_drill/report.json` + actual delivery-channel record | local rehearsal automated; external delivery not verified |
