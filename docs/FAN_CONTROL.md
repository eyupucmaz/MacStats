# Future Fan-Control Feasibility

## Status in v0.2.0

MacStats v0.2.0 is monitoring-only. It can read fan RPM and temperature when
the hardware exposes those values, but it does not set fan mode or RPM.

Fan control is safety-sensitive. A partial write, race, crash, or `SIGKILL`
while a Mac is in a manual hardware state could leave cooling in an unsafe
state. macOS does not provide a stable public, high-level API for fan control,
so a future implementation cannot treat model-specific SMC behavior as a
portable Apple contract.

## A separate privileged architecture

Any future control feature must be a separately installed, least-privileged
helper rather than a capability of the menu bar app. The GUI should remain
unprivileged. A helper design must include all of the following:

- Registration and lifecycle management through
  [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice),
  with an explicit administrator approval flow.
- Authenticated IPC that validates the caller's audit token before accepting a
  request.
- Strict RPM and model allowlists; unknown models and unvalidated limits must
  fail closed.
- A watchdog or lease that returns the device to automatic mode if the client,
  helper, or connection fails.
- Unconditional restoration of automatic mode during normal shutdown, error
  handling, and lease expiry.

Apple's [least-privilege guidance](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/AccessControl.html)
recommends a separate helper only for the privileged work that cannot be avoided.
The proposed GUI/helper separation also follows the privacy and trust principles
described in Apple's [WWDC22 privacy guidance](https://developer.apple.com/videos/play/wwdc2022/10096/).

## Suggested path

1. Read-only key mapping on each supported device, with no write operations.
2. A narrowly scoped helper prototype.
3. Fail-safe tests on supported devices, including interruption and restoration
   paths.
4. A signed and [notarized](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
   opt-in preview.

Community SMC research can inform investigation, but it is reverse engineering,
not an Apple contract. A future project must not silently escalate privileges or
copy reverse-engineered key mappings without per-model validation.
