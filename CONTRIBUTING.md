# Contributing to MacStats

Thank you for improving MacStats. MacStats monitors your Mac and offers optional
audio controls; it never writes fan or SMC settings. Please keep contributions
within that scope.

## Prerequisites

- macOS 13.5 (Ventura) or later, as required by Xcode 15.1.
- Xcode 15.1 or later (macOS 14.2 SDK). The per-app audio mixer uses CoreAudio
  process taps, which need the macOS 14.2 SDK to build. The app itself still
  runs on macOS 13 or later.

## Before opening a pull request

Run the required local checks:

```bash
swift test
bash Scripts/check-monitoring-only.sh
for script in Scripts/*.sh; do bash -n "$script"; done
bash Tests/ReleaseSafetyTests.sh
```

CI also runs `shellcheck Scripts/*.sh Tests/*.sh` (ShellCheck 0.9 on Ubuntu 24.04).

Do not add product code or tests that write to SMC. Fan and SMC access stays
read-only, and the safety check must continue to pass. Audio changes must keep
audio processing local: never record, store, or send captured audio.

Keep commits focused. Open an issue before proposing a broad behavioral change
so maintainers and contributors can agree on scope first.

## Documentation screenshots

The popover images in `docs/assets` come from a gated test that hosts the real
popover, records about five and a half minutes of genuine readings, then
captures the card grid and each detail page by window ID (never the whole
screen): `MACSTATS_SCREENSHOTS=1 MACSTATS_SCREENSHOTS_DIR=/tmp/shots swift test
--filter DocScreenshotTests`. The popover appears on screen while it runs; the
other `MACSTATS_SCREENSHOTS_*` options (warm-up, pages, appearance, per-page
height caps) are documented in `Tests/MacStatsTests/DocScreenshotTests.swift`.
Before committing an image, check it for personal data: IP or MAC addresses,
network, computer or user names, volume names other than Macintosh HD, and
process names other than well-known apps.

## Releases

Releases are cut by pushing a `vMAJOR.MINOR.PATCH` tag that matches
`CFBundleShortVersionString` in `Info.plist`. `.github/workflows/release.yml`
then refuses to publish unless:

- the tag points at a commit on `main`;
- the `CI` workflow concluded `success` for a push of that exact commit
  (`Scripts/require-ci-success.sh` waits while CI is still running). If several
  commits reached `main` in one push, or CI was cancelled, tag a commit whose CI
  passed;
- the publish job is allowed by the protected `release` environment, which
  only accepts tags matching `v*.*.*`. To re-run a release by hand, dispatch it
  from the tag: `gh workflow run release.yml --ref v0.2.0 -f tag=v0.2.0`.

`CFBundleVersion` is the number of commits reachable from the built commit
(`Scripts/build-number.sh`), so the same commit always gets the same build
number. It needs a full clone, not a shallow one.

## Signing and notarization

Release builds are currently ad-hoc signed with the hardened runtime and are
not notarized. `Scripts/build-app.sh` signs the bundle once, without `--deep`;
`Scripts/verify-app.sh` fails if the bundle gains nested code (sign such code
explicitly, inside out, first) or any entitlement that is not listed in its
`ALLOWED_ENTITLEMENTS` array, which is empty today. To ship an entitlement,
pass an entitlements plist to `codesign` in `build-app.sh`, add the key to
`ALLOWED_ENTITLEMENTS`, and justify it in the pull request.

What this means for the App Mixer (CoreAudio process taps, macOS 14.2+):

- **Permission identity.** macOS records an app's designated requirement (DR)
  with a privacy grant and checks later versions against it. An ad-hoc DR is
  tied to that build's code hash, so each new build is a different app to TCC:
  expect the "system audio recording" grant to be asked for again after every
  update, and stale entries to pile up in System Settings. A Developer ID
  signature gives a DR based on the bundle identifier and Team ID, which
  survives updates. (Apple, TN3127: Inside Code Signing: Requirements.)
- **Entitlements.** Apple's process-tap documentation requires only the
  `NSAudioCaptureUsageDescription` Info.plist key, which MacStats has.
  `com.apple.security.device.audio-input` is the hardened-runtime entitlement
  for the microphone and Core Audio *input*; without it macOS denies
  microphone access to hardened apps. Apple does not say whether taps need it,
  and Apple-adjacent samples (AudioCap) ship it. Do not add it on speculation:
  check on a clean Mac whether a hardened build's App Mixer receives audio
  (failures are silent, with zero-filled buffers), and add the entitlement
  through the allowlist only if it is needed.

Recommended path once an Apple Developer Program membership is available:

1. Create a *Developer ID Application* certificate and an App Store Connect
   API key with the Developer role.
2. Store these as secrets of the `release` environment: `DEVELOPER_ID_P12_BASE64`,
   `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_KEY_P8_BASE64`,
   `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. Environment secrets are only given to
   jobs that declare the environment, so the signing build job must declare
   `environment: release` too.
3. In that job, import the certificate into a temporary keychain
   (`security create-keychain`, `security import`,
   `security set-key-partition-list`) and build with
   `CODE_SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)"
   CODE_SIGN_TIMESTAMP=1 bash Scripts/build-app.sh`.
4. Sign the DMG (`codesign --timestamp --sign "<identity>" <dmg>`), then
   notarize and staple it:
   `xcrun notarytool submit <dmg> --key AuthKey.p8 --key-id "$NOTARY_KEY_ID"
   --issuer "$NOTARY_ISSUER_ID" --wait`, `xcrun stapler staple <dmg>`.
5. Verify with `spctl --assess --type open --context context:primary-signature -v <dmg>`
   and `spctl --assess --type execute -v MacStats.app`; have `verify-app.sh`
   require the Developer ID DR (`codesign --verify -R '=anchor apple generic and
   identifier "com.eyupucmaz.MacStats" and certificate leaf[subject.OU] = "<TEAM_ID>"'`).
   Compute the checksum after stapling, then update the release notes, which
   currently say the build is ad-hoc signed and not notarized.

Until then, the ad-hoc limitation above is a known, documented trade-off.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
