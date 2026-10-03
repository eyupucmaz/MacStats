# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Audio tab in the popover: choose the default output and input device and set
  the output device's volume and mute.
- Per-app App Mixer to adjust or mute the volume of individual apps (macOS 14.2
  or later). It is off by default and asks for system audio-capture permission
  when enabled; audio is processed locally and never recorded, stored, or sent.
- Turkish localization. MacStats follows the macOS language (English or
  Turkish), including VoiceOver labels and the audio-capture permission prompt;
  the compact menu bar labels stay untranslated.

### Changed

- The Disk metric now shows startup-volume capacity (percent used and free
  space, in decimal GB like Finder) instead of read/write throughput.
- The `disk` menu bar item now shows percent used (for example, `DSK 97%`)
  instead of throughput.
- Building from source now requires Xcode 15.1 or later (macOS 14.2 SDK).

## [0.1.0] - 2026-09-04

### Added

- Read-only macOS system monitoring in a menu bar app.
- Universal 2 DMG packaging and automated verification.

[Unreleased]: https://github.com/eyupucmaz/MacStats/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0
