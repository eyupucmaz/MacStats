# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-08

### Added

- Audio tab in the popover: choose the default output and input device and set
  the output device's volume and mute.
- Per-app App Mixer to adjust or mute the volume of individual apps (macOS 14.2
  or later). It is off by default and asks for system audio-capture permission
  when enabled; audio is processed locally and never recorded, stored, or sent.
- Turkish localization. MacStats follows the macOS language (English or
  Turkish), including VoiceOver labels and the audio-capture permission prompt;
  the compact menu bar labels stay untranslated.
- A one-time welcome hint on first launch: the popover opens once and explains
  the menu bar item, the System and Audio tabs, Settings, and the ⋯ menu until
  you dismiss it.
- Metric detail pages: click any card in the System tab to open its page in the
  same popover, with charts over 1 minute, 5 minutes, 15 minutes or 1 hour (hover
  for the exact value and time; min, avg and max for the visible range). Back with
  the chevron, Esc or ⌘[. History stays in memory for the last hour and is never
  written to disk. The pages:
  - **CPU:** user/system split and history, per-core load, load average, top
    processes, chip facts and thermal state.
  - **GPU:** utilization history with the renderer/tiler split when reported,
    GPU memory, and each GPU's model, cores and Metal device.
  - **Memory:** used memory and memory pressure over time, the Activity Monitor
    breakdown, swap and paging rates, top processes, physical memory.
  - **Disk:** startup-disk capacity, every mounted volume, read/write activity,
    processes by disk I/O, and the drive's model and connection.
  - **Network:** download/upload history, totals since MacStats started and since
    boot, each interface with its addresses and link speed, Wi-Fi signal details.
  - **Battery:** charge history with the power-source band, battery power, time
    remaining, power adapter, battery health and Low Power Mode.
  - **Fan:** speed history and each fan's minimum, maximum and target speed.
  - **Temperature:** CPU temperature history with the thermal-state band, and
    every mapped SMC sensor with its session low and high.
- A **Details** submenu in the menu bar item's right-click menu (and the popover's
  ⋯ menu) opens the popover straight on a metric's page, and a setting opens the
  page when you click a menu bar item that shows a single metric.
- Turkish translations of all new text, including VoiceOver labels.

### Changed

- The Disk metric now shows startup-volume capacity (percent used and free
  space, in decimal GB like Finder) instead of read/write throughput.
- The `disk` menu bar item now shows percent used (for example, `DSK 97%`)
  instead of throughput.
- Building from source now requires Xcode 15.1 or later (macOS 14.2 SDK).
- Performance: the closed popover no longer re-renders on every refresh, charts
  are drawn on a canvas instead of one mark per sample, a page applies its
  updates once per refresh, and core bars and fan gauges animate with Core
  Animation. An open detail page now costs about what the card grid does.

### Known issues

- The build is still ad-hoc signed, so macOS asks for the App Mixer's
  audio-capture permission again after each update.

## [0.1.0] - 2026-09-04

### Added

- Read-only macOS system monitoring in a menu bar app.
- Universal 2 DMG packaging and automated verification.

[Unreleased]: https://github.com/eyupucmaz/MacStats/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/eyupucmaz/MacStats/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0
