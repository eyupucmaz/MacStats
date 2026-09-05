# Contributing to MacStats

Thank you for improving MacStats. Please keep contributions focused on the
monitoring-only public preview.

## Prerequisites

- macOS 13 (Ventura) or later.
- Xcode or a Swift toolchain compatible with Swift tools 5.9.

## Before opening a pull request

Run the required local checks:

```bash
swift test
bash Scripts/check-monitoring-only.sh
for script in Scripts/*.sh; do bash -n "$script"; done
```

Do not add product code or tests that write to SMC. The project is
monitoring-only, and the safety check must continue to pass.

Keep commits focused. Open an issue before proposing a broad behavioral change
so maintainers and contributors can agree on scope first.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
