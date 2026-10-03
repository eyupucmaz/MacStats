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
```

Do not add product code or tests that write to SMC. Fan and SMC access stays
read-only, and the safety check must continue to pass. Audio changes must keep
audio processing local: never record, store, or send captured audio.

Keep commits focused. Open an issue before proposing a broad behavioral change
so maintainers and contributors can agree on scope first.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
