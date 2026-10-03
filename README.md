# MacStats

[Website](https://eyupucmaz.github.io/MacStats/) · [Wiki & user guide](https://eyupucmaz.github.io/MacStats/guide.html) · [Download](https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0)

MacStats is a lightweight macOS menu bar app that monitors your Mac. It never
writes fan or SMC settings. The v0.1.0 public preview requires macOS 13
(Ventura) or later.

It reports CPU, memory, GPU, disk capacity, network, and battery metrics. When
the hardware exposes them, it also reports fan RPM and temperature. Fan speed
is a reading only: MacStats does not include fan control.

The development version on `main` (coming in v0.2.0) also adds optional audio
controls in a new Audio tab; see [Audio controls](#audio-controls). The v0.1.0
download does not include them.

## Download and install

Download the v0.1.0 public preview from
[GitHub Releases](https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0). The
v0.1.0 release assets are `MacStats-0.1.0-universal.dmg` and
`MacStats-0.1.0-universal.dmg.sha256`.

1. Open the DMG and drag `MacStats.app` to Applications.
2. Because this preview is ad-hoc signed and not notarized, open it with
   Control-click → **Open**, or choose **Open Anyway** in System Settings →
   Privacy & Security.
3. MacStats runs from the menu bar rather than the Dock.

Verify the downloaded DMG before opening it:

```bash
cd ~/Downloads
shasum -a 256 -c MacStats-0.1.0-universal.dmg.sha256
```

## Audio controls

Coming in v0.2.0 and available on `main`. The popover has a **System** tab for
metrics and an **Audio** tab with optional controls:

- **Devices:** choose the default output and input device, and set the output
  device's volume and mute. These work on macOS 13 or later.
- **App Mixer:** adjust the volume of, or mute, individual apps that are
  playing audio. The mixer requires macOS 14.2 or later, is off until you
  select **Enable App Mixer**, and stays active only while enabled. The first
  time you enable it, macOS asks for system audio-capture permission.

## Languages

Coming in v0.2.0 and available on `main`. MacStats is available in English and
Turkish and follows your macOS language. To change it for MacStats only, use
System Settings → General → Language & Region → Applications. The three-letter
menu bar labels (`CPU`, `RAM`, `DSK`, `NET`, …) and unit symbols stay the same
in every language to keep the menu bar compact.

Translations live in `Sources/MacStats/Resources/<language>.lproj/Localizable.strings`
(app text) and `AppResources/<language>.lproj/InfoPlist.strings` (macOS
permission prompts); `swift test` checks that every language has every string.

## Privacy

MacStats reads local system metrics. It has no accounts, no telemetry, and no
network data upload by the app. Preferences are saved locally on your Mac.

Audio capture (v0.2.0 / `main`): the App Mixer needs system audio-capture
permission so it can adjust each app's volume. Audio is processed live on your
Mac only while the mixer is enabled; it is never recorded, stored, or sent
anywhere. You can revoke the permission at any time in System Settings →
Privacy & Security → Screen & System Audio Recording.

## Limitations

- Hardware and SMC metric availability varies by Mac model and macOS version.
  Unavailable metrics are shown as unavailable rather than invented.
- Fan control is not included. MacStats never writes fan or SMC settings.
- The per-app App Mixer requires macOS 14.2 or later; on earlier versions the
  Audio tab offers device selection and output volume only.
- The public preview uses an ad-hoc signature. An ad-hoc signature is not
  notarization.
- CI verifies the packaged app as Universal 2 (`arm64` and `x86_64`); this is
  build verification, not a claim that every metric is available on every Mac.

## Build, test, and package

Building the audio code requires Xcode 15.1 or later (the macOS 14.2 SDK). The
built app still runs on macOS 13 or later. Then run:

```bash
swift build
swift test
bash Scripts/check-monitoring-only.sh
for script in Scripts/*.sh; do bash -n "$script"; done

APP_VERSION=0.1.0 BUILD_NUMBER=1 RELEASE_STRICT=1 bash Scripts/build-app.sh
bash Scripts/package-dmg.sh 0.1.0
bash Scripts/verify-release.sh 0.1.0 1
```

The package command produces `dist/MacStats-0.1.0-universal.dmg` and its
`.sha256` checksum file.

## Contributing and roadmap

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
- Report security issues privately as described in [SECURITY.md](SECURITY.md).
- Community expectations are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- MacStats is available under the [MIT License](LICENSE).
- The future privileged-helper exploration is documented in
  [docs/FAN_CONTROL.md](docs/FAN_CONTROL.md).

MacStats is maintained by [Eyüp Uçmaz](https://github.com/eyupucmaz).

Visit the [MacStats website](https://eyupucmaz.github.io/MacStats/) for screenshots and the [complete user guide](https://eyupucmaz.github.io/MacStats/guide.html).
