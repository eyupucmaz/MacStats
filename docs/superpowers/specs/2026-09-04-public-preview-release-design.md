# MacStats Public Preview Release Design

**Date:** 2026-09-04

**Status:** Approved for planning

**Release:** v0.1.0 Public Preview

**Repository:** `https://github.com/eyupucmaz/MacStats`

## Context

MacStats is a SwiftPM-based macOS menu bar monitor. The current application
builds and its 68 unit tests pass locally, but the existing distribution bundle
is arm64-only, ad-hoc signed, unnotarized, and rejected by Gatekeeper. The source
also contains an in-process SMC fan-write path that is unavailable during normal
app execution and lacks the failure isolation required for public distribution.

The first public release will therefore be a transparent, unsigned public
preview focused on monitoring. The release will be downloadable as a Universal
2 DMG, with the required first-launch Gatekeeper steps documented. Developer ID
signing and notarization remain a future enhancement because no Developer ID
Application identity is currently installed.

## Goals

1. Publish MacStats as a public MIT-licensed repository owned by `eyupucmaz`.
2. Produce a repeatable Universal 2 DMG release for Intel and Apple Silicon.
3. Add least-privilege CI for tests and release-quality bundle validation.
4. Publish v0.1.0 as an explicitly unnotarized GitHub pre-release.
5. Make the shipped application monitoring-only and remove reachable SMC writes.
6. Provide the standard documentation needed by users and contributors.
7. Leave the machine's active GitHub CLI account as `eucmaz` after publication.

## Non-goals

- Implementing production fan control in v0.1.0.
- Mac App Store distribution.
- Adding auto-update, telemetry, analytics, or network communication.
- Obtaining or creating Apple Developer credentials.
- Solving all Swift 6 strict-concurrency migration warnings in this release.
- Claiming that every private SMC or GPU metric works on every Mac model.

## Product Scope and Fan Safety

### v0.1.0 behavior

The release will continue to display fan RPM and temperature when the relevant
SMC keys are readable. Manual modes, custom RPM controls, and direct SMC writes
will not ship as reachable functionality.

The existing in-process write implementation will be removed from the shipping
target rather than merely hidden behind a disabled control. Git history retains
the original implementation for reference. Unit tests must not call a real SMC
write path; hardware-dependent reads remain fail-soft and report unavailable
rather than synthesizing values.

The README and UI will describe fan data as monitoring. They will not advertise
Intel-only control, best-effort control, or a functional manual mode.

### Future fan-control milestone

Fan control will be designed as a separate direct-distribution capability:

1. The GUI continues to run as the signed-in user.
2. A minimal root LaunchDaemon is registered through
   `SMAppService.daemon(plistName:)` after explicit administrator approval.
3. The app talks to the daemon over a narrow XPC protocol containing only
   capability discovery, set-target, restore-auto, and heartbeat operations.
4. The helper authenticates the client using its audit token and code-signing
   requirement. It never accepts arbitrary SMC keys, commands, or executable
   paths.
5. RPM limits are read from hardware and enforced independently by both client
   and helper. Missing limits disable control; fallback numbers are never written.
6. Mode and target changes are transactional. Any failed write or failed
   read-back immediately attempts to restore automatic control.
7. A short lease/watchdog restores every fan to automatic control when the app
   disconnects, heartbeats stop, thermal state becomes unsafe, or the helper
   restarts.
8. Sleep/wake and helper-upgrade paths re-probe capabilities and begin in auto.
9. Runtime probing handles fan count, `F<n>Md`/`F<n>md`, Intel `FS! `, optional
   `Ftst`, key data types, and firmware-specific behavior. No generation is
   assumed from the marketing model name alone.
10. The `Silent` preset is excluded. Any future automatic curve must use
    hysteresis, a safe minimum, and a highest-demand-wins policy.

That milestone requires Developer ID signing, notarization, an independent
security review of the privileged helper, and a hardware matrix covering fanless,
single-fan, and multi-fan Intel/T2/M1-M5 systems.

## Repository and Community Files

The public repository will use `main` as its default branch and include:

- A user-first `README.md` with a latest-release download link, DMG installation,
  Gatekeeper instructions, features, privacy statement, limitations, build/test
  commands, support links, and `https://eyupucmaz.dev`.
- The existing MIT `LICENSE`, retaining the 2026 Eyüp Uçmaz copyright.
- `CHANGELOG.md` following Keep a Changelog conventions.
- `CONTRIBUTING.md` with local setup, tests, scope, and pull-request expectations.
- `SECURITY.md` with private vulnerability-reporting guidance and supported
  versions.
- `CODE_OF_CONDUCT.md` using Contributor Covenant 2.1 with a contact method.
- Bug report and feature request forms plus a concise pull-request template.
- `docs/FAN_CONTROL.md` documenting current limitations and the safe future
  architecture without presenting reverse-engineered behavior as an Apple API.

No analytics, donation links, generated marketing claims, or unsupported hardware
compatibility promises will be added.

## Build and Packaging

### Versioning

- Git tags use semantic versions such as `v0.1.0`.
- `CFBundleShortVersionString` is derived from the tag (`0.1.0`).
- `CFBundleVersion` is an integer build number supplied by CI and defaults to `1`
  for local builds.
- Packaging rejects malformed versions and a tag/source-version mismatch.

### App bundle

`Scripts/build-app.sh` will support a Universal 2 release build using SwiftPM's
`--arch arm64 --arch x86_64` mode and locate the corresponding
`.build/apple/Products/Release` outputs. Local single-architecture builds remain
available when explicitly requested.

The script will stage version metadata into the generated app rather than mutate
the source plist. Release mode treats a missing executable, resource bundle,
`Assets.car`, icon, malformed plist, wrong bundle identifier, or wrong
architecture as a hard failure.

The current public preview uses an ad-hoc hardened-runtime signature. The script
will accept a signing identity and timestamp options through environment inputs
so a future release can replace the ad-hoc signature with Developer ID signing
without changing bundle assembly.

### DMG

`Scripts/package-dmg.sh` will create a compressed, read-only DMG containing:

- `MacStats.app`
- an `/Applications` symlink for drag-and-drop installation

The output name will be `MacStats-0.1.0-universal.dmg`. Packaging will produce
`MacStats-0.1.0-universal.dmg.sha256`. A release verification script will mount
the DMG without browsing it, validate the contained app, then detach it even on
failure.

## Continuous Integration

`.github/workflows/ci.yml` will run on pull requests and pushes to `main` with
`contents: read` only.

The workflow will:

1. Check out the exact revision using an action pinned to a full commit SHA.
2. Run the XCTest suite on an arm64 macOS runner.
3. Run the XCTest suite on an Intel macOS runner.
4. Build the Universal 2 app once.
5. Validate bundle structure, plist values, icon/resources, architectures, and
   code-signature integrity.
6. Run shell syntax checks for repository scripts.

CI never receives signing or notarization secrets and never performs an SMC
write. Concurrency cancellation will supersede stale runs from the same branch.

## Release Automation

`.github/workflows/release.yml` will run only for semantic `v*` tags and optional
manual dispatch. Manual dispatch requires an existing semantic tag as input and
checks out that tag; it cannot release an arbitrary branch tip. The workflow will
use `contents: write`; all other token permissions remain disabled.

The release job will:

1. Validate the tag and check out that immutable revision.
2. Run tests.
3. Build and ad-hoc sign the Universal 2 app with the tag-derived version.
4. Run bundle and architecture verification.
5. Create and mount-verify the DMG.
6. Generate SHA-256 output.
7. Create a GitHub pre-release and upload the DMG plus checksum.

Any failed gate prevents release creation. The workflow will not describe an
ad-hoc build as notarized, Gatekeeper-approved, or seamless to install.

Developer ID support will be added later as a distinct signing/notarization path:
import a temporary certificate into an ephemeral keychain, sign nested code from
the inside out with hardened runtime and a secure timestamp, submit with
`notarytool`, staple the accepted ticket, and require `spctl` acceptance before
publication.

## GitHub Account and Publication Procedure

The directory starts as a local Git repository so its pre-release state is
recoverable. Implementation will occur on an isolated worktree branch after this
spec and its plan are approved.

For publication:

1. Confirm the current active GitHub account is `eucmaz`.
2. Switch to `eyupucmaz` only for repository creation and authenticated pushes.
3. Create public repository `eyupucmaz/MacStats`, set its homepage to
   `https://eyupucmaz.dev`, and push `main`.
4. Restore the active account to `eucmaz` immediately, using an exit trap for
   failure paths.
5. Verify CI on `main`.
6. If a fix requires another push, repeat the same bounded account-switch block.
7. Push annotated tag `v0.1.0`, restore `eucmaz`, wait for the release workflow,
   and verify its public assets.
8. Finish by proving `gh auth status` identifies `eucmaz` as active.

No force push, credential export, token output, or fallback GitHub account is
permitted.

## Error Handling and Recovery

- A failed test, build, bundle check, DMG mount, or checksum check blocks the tag.
- The release workflow must detach mounted images and delete temporary keychains
  on every exit path.
- GitHub account restoration runs on both success and shell failure.
- If repository creation succeeds but push fails, the empty repository is kept
  and reported rather than deleted automatically.
- If the tag workflow fails, the tag and failed run are preserved for diagnosis;
  no replacement artifact is uploaded manually under the same version.
- No fan write is used as a release or CI validation step.

## Verification Strategy

Local verification before publication:

- `swift test`
- fan tests backed only by non-hardware logic or test doubles
- `bash -n` for each shell script
- Universal 2 release build
- `plutil -lint` and explicit bundle metadata assertions
- `lipo -archs`/`file` checks for arm64 and x86_64
- `codesign --verify --deep --strict` for the ad-hoc public-preview bundle
- DMG attach, contained-app validation, and guaranteed detach
- SHA-256 generation and verification
- sensitive-pattern scan excluding generated output
- final clean Git status

Remote verification:

- `main` CI completes successfully on both runner architectures
- v0.1.0 release workflow completes successfully
- release is visibly marked as a pre-release
- DMG and checksum assets exist and are downloadable
- repository visibility, owner, homepage, default branch, license detection, and
  release URL match the design
- active local GitHub account is restored to `eucmaz`

## Acceptance Criteria

The work is complete when:

1. `https://github.com/eyupucmaz/MacStats` is public and contains the reviewed
   source, community documentation, CI, and release automation.
2. The default public build has no reachable in-process SMC write operation.
3. Local and remote tests/build validation pass without real hardware writes.
4. GitHub Release v0.1.0 is a pre-release containing a Universal 2 DMG and a
   matching SHA-256 file.
5. Installation and Gatekeeper limitations are accurate in the README and release
   notes.
6. Fan control requirements and safety gates are documented separately.
7. `eucmaz` is the active GitHub CLI account after all remote operations.
