# MacStats

MacStats is a lightweight, read-only macOS menu bar app for monitoring local
system metrics. The v0.1.0 public preview requires macOS 13 (Ventura) or later.

It reports CPU, memory, GPU, disk I/O, network, and battery metrics. When the
hardware exposes them, it also reports fan RPM and temperature. This preview is
monitoring-only: it does not include fan control.

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

## Privacy

MacStats reads local system metrics. It has no accounts, no telemetry, and no
network data upload by the app.

## Limitations

- Hardware and SMC metric availability varies by Mac model and macOS version.
  Unavailable metrics are shown as unavailable rather than invented.
- Fan control is not included in v0.1.0.
- The public preview uses an ad-hoc signature. An ad-hoc signature is not
  notarization.
- CI verifies the packaged app as Universal 2 (`arm64` and `x86_64`); this is
  build verification, not a claim that every metric is available on every Mac.

## Build, test, and package

Use a Swift tools 5.9-compatible toolchain on macOS 13 or later:

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

MacStats is maintained by [Eyüp Uçmaz](https://eyupucmaz.dev).
