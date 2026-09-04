# MacStats

A lightweight macOS menubar app that reports live system statistics — CPU, memory,
GPU, disk I/O, network, battery, temperature and fan speed — from an `LSUIElement`
agent that stays out of the Dock.

MacStats reads from the OS. It does **not** make network connections, does not
phone home, and ships with no analytics.

## Features

| Metric | Source |
|---|---|
| **CPU usage** | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` — per-core tick deltas between samples |
| **Memory** | `host_statistics64(HOST_VM_INFO64)`; total from `ProcessInfo.physicalMemory` |
| **GPU usage** | IOKit `IOAccelerator` / `AGXAccelerator` registry node, `PerformanceStatistics` dictionary |
| **Disk I/O** | `IOBlockStorageDriver` `Statistics` (bytes read/written), differenced per sample |
| **Network** | `getifaddrs()` → `if_data.ifi_ibytes` / `ifi_obytes`, summed over active interfaces |
| **Battery** | `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription`, plus `AppleSmartBattery` for health and cycle count |
| **Temperature / fan RPM** | `AppleSMC` via IOKit |
| **Fan control** | `AppleSMC` writes — see [Limitations](#limitations-read-this) |

Settings let you choose which rows are displayed, which metrics are drawn
directly in the menu bar, the update interval (1s / 2s / 5s / 30s), and whether
MacStats launches at login (via `SMAppService`).

### Menu bar display

Any of the eight metrics can be shown in the menu bar itself, as a label and a
value — `CPU 23%  RAM 8.2G  TMP 53°C` — so the common ones are readable without
opening the popover. Selecting none restores the plain app icon. The title is
drawn into a *template* image with monospaced digits: template images let the
system invert the text for dark menu bars and for the highlighted state, and
monospaced digits stop the item's width from jittering (and shoving its
neighbours) as values change. Each metric costs roughly 55-100pt of bar width,
so two or three is the practical limit.

One trade-off is unavoidable: with metrics in the menu bar, sampling must run
continuously rather than only while the popover is open. Measured cost on an
M5 is about 0.1% CPU at a 1s interval, against 0.0% when idle-paused. Turning
off every menu bar metric restores the paused behaviour.

## Limitations (read this)

These are real constraints of the platform, not TODOs. MacStats reports a metric
as **unavailable** rather than showing an invented number.

- **Fan control writes require root, and generally do not work on Apple Silicon.**
  Writing an SMC fan target key from an unprivileged, unsigned user-space process
  is rejected on Apple Silicon Macs. MacStats detects this and surfaces fan
  control as unavailable (with the underlying error) instead of pretending the
  write landed. Treat the fan-control UI as best-effort; on most modern Macs it
  will simply report that it cannot take over from macOS thermal management.
- **Some Macs are fanless.** MacBook Air (all Apple Silicon models), Mac mini in
  some configurations under light load, and iPad-derived hardware have no fan to
  read or drive. MacStats shows the fan row as unavailable there.
- **SMC sensor keys are model-specific.** The temperature key that works on one
  Mac may not exist on another; MacStats probes at startup and hides the
  temperature row when no key responds. Whether temperature and fan RPM read
  successfully on *your* machine depends on your model and macOS version.
- **GPU utilization keys are private and undocumented.** The
  `PerformanceStatistics` dictionary differs between GPU families and macOS
  releases. Where no recognised key is present the GPU row reads 0/unavailable.
- **Battery is absent on desktop Macs**, which report as "AC Power" with no
  level. `AppleSmartBattery` health and cycle-count keys are not present on
  every model.
- **Disk and network figures are host-wide**, not per-process, and are rates
  derived from counter deltas between samples — a very short interval makes
  them noisy.
- **No sandbox, no entitlements.** MacStats uses public IOKit and Mach APIs that
  need no entitlement. It is distributed unsandboxed and unnotarized; see
  [Gatekeeper](#gatekeeper) below.

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+ toolchain (Xcode 15+ or the Swift toolchain plus Command Line Tools)
- Apple Silicon or Intel. Metrics work on both; fan *control* is effectively
  Intel-and-root-only, as described above.

## Building

### The app bundle (what you actually want)

`swift build` alone produces a bare Mach-O executable, which is **not** enough:
`LSUIElement` (no Dock icon), the bundle identifier, the icon and launch-at-login
via `SMAppService` all require a real `.app` bundle. Use the packaging script:

```bash
./Scripts/build-app.sh
# or
make app
```

That script:

1. runs `swift build -c release`
2. assembles `dist/MacStats.app/Contents/{MacOS,Resources}` with the executable,
   `Info.plist`, a `PkgInfo`, and the SwiftPM-generated resource bundle
   (`MacStats_MacStats.bundle`) so `Bundle.module` resolves at runtime
3. compiles `Sources/MacStats/Resources/Assets.xcassets` into `Assets.car`
   (plus `AppIcon.icns`) with `actool` when the installed developer tools
   provide it — it warns and continues if `actool` is missing or the asset
   catalog holds no icon images, and strips the icon keys from the bundled
   `Info.plist` so the bundle never advertises an icon it does not have
4. ad-hoc codesigns the bundle (`codesign --force --deep --sign - --options runtime`)
   so macOS will launch it
5. prints the resulting path, install instructions and the Gatekeeper caveat

### The app icon

The icon is generated, not hand-drawn: `Scripts/make-icon.swift` renders every
size in the asset catalog with Core Graphics — bars of ascending height in an
ascending green→red thermal ramp on a graphite squircle. Each size is drawn
natively rather than downsampled from one master, and 16/32pt use a simplified
three-bar variant because four bars collapse into mush at that scale.

```bash
make icon    # re-render Sources/MacStats/Resources/Assets.xcassets/AppIcon.appiconset
```

The tile is deliberately close to edge-to-edge: macOS 26 re-frames legacy
`.icns` icons inside its own container, so a Big Sur-style 100pt margin shows up
as a visible tile-inside-a-tile. The artwork keeps its own squircle (macOS 15
and earlier do no masking of their own) but leaves only a small margin, which
reads correctly on both. None of this affects the menu bar item, which draws
either an SF Symbol or the live metric text — see [Menu bar display](#menu-bar-display).

### Make targets

```bash
make build      # swift build (debug)
make release    # swift build -c release
make app        # Scripts/build-app.sh → dist/MacStats.app
make icon       # re-render the app icon into the asset catalog
make test       # swift test
make run        # build the bundle and open it
make clean      # remove .build/ and dist/
```

### Xcode

Open `Package.swift` in Xcode and build the `MacStats` scheme. Note that running
from Xcode runs the bare executable, so launch-at-login will report itself as
unsupported; use `make app` when you need bundle-dependent behaviour.

## Installing

```bash
make app
cp -R dist/MacStats.app /Applications/
open /Applications/MacStats.app
```

MacStats has no Dock icon and no window on launch — look for its icon in the
menubar and click it.

### Gatekeeper

The bundle is signed **ad hoc** (`codesign --sign -`) and is **not notarized**.
A bundle you build locally is not quarantined, so `open` works immediately. A
copy you download or receive from someone else will be quarantined and macOS
will refuse it with "cannot be opened because the developer cannot be verified".
To open it anyway: right-click the app in Finder → **Open** → confirm, or
System Settings → Privacy & Security → **Open Anyway**, or
`xattr -dr com.apple.quarantine /Applications/MacStats.app`.

Shipping this without those steps requires a paid Apple Developer ID certificate
and notarization, which this repository does not include.

## Testing

```bash
swift test
# or
make test
```

The suite in `Tests/MacStatsTests/` tests the public contracts of `StatsEngine`
and `FanController`: clamping of custom fan speeds and update intervals, stable
`FanMode` raw values, published percentages staying inside 0…100, `memoryTotal`
matching `ProcessInfo.processInfo.physicalMemory`, and start/stop lifecycle
safety. The tests deliberately assert nothing that depends on the host hardware,
so they pass on a fanless Mac, on a desktop without a battery, and in CI where
SMC access fails.

## Fan control modes

| Mode | Intent |
|---|---|
| **Auto** | Hand control back to macOS thermal management |
| **Silent** | Low fixed target — quieter, warmer |
| **Balanced** | Moderate fixed target |
| **Max** | Maximum fixed target |
| **Custom** | User-selected RPM, clamped to the reported min/max |

⚠️ Manual fan control overrides macOS thermal management. Where the write is
permitted at all, keep an eye on temperature and return to **Auto** if things
get hot. On hardware where the write is refused, MacStats reports the mode as
unavailable and does not change your fan.

## Project layout

```
MacStats/
├── Package.swift                 # SwiftPM manifest (executable + test target)
├── Info.plist                    # Bundle metadata, copied in by Scripts/build-app.sh
├── Makefile                      # build / release / app / test / run / clean
├── Scripts/
│   └── build-app.sh              # Produces dist/MacStats.app
├── Sources/MacStats/
│   ├── main.swift                # NSApplication entry point
│   ├── AppDelegate.swift         # Status item + popover
│   ├── StatsEngine.swift         # Sampling loop, published metrics
│   ├── FanController.swift       # SMC fan reads/writes and availability
│   ├── System/                   # CPU, Memory, GPU, Disk, Network, Battery, SMC
│   ├── Settings/                 # AppSettings, LaunchAtLogin
│   ├── Views/                    # StatsView (popover), SettingsView
│   └── Resources/Assets.xcassets # App icon & accent colour
└── Tests/MacStatsTests/          # XCTest contract tests
```

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Eyüp Uçmaz.

## Credits

- SMC key research from the `smcFanControl` and *Macs Fan Control* projects
- Menubar and row icons from SF Symbols
- Built with SwiftUI and AppKit
