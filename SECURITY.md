# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| `0.1.x` | Preview-supported |

## Reporting a vulnerability

For a potentially exploitable security issue, use GitHub Private Vulnerability
Reporting: <https://github.com/eyupucmaz/MacStats/security/advisories/new>.

Please do not open a public issue for an exploitable finding. Include enough
detail to reproduce and assess the issue without publishing sensitive details.
We will acknowledge the report and provide updates as investigation progresses;
we do not promise a fixed response or resolution deadline.

## Scope and privacy

MacStats monitors your Mac. It never writes fan or SMC settings, has no
accounts or telemetry, and does not upload data.

Starting with v0.2.0 (available on `main`), the optional App Mixer (macOS 14.2
or later) uses system audio-capture permission to adjust per-app volume. Audio
is processed live on the Mac only while the mixer is enabled and is never
recorded, stored, or sent. Users can revoke the permission in System Settings →
Privacy & Security → Screen & System Audio Recording. The Audio tab can also
change the default output and input device and the output volume and mute.

Reports about audio capture outside these limits, or any write to fan or SMC
settings, are in scope for this policy.
