# MacStats Public Preview Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish MacStats as a monitoring-only open-source macOS app under `eyupucmaz/MacStats`, with a verified Universal 2 DMG and repeatable GitHub CI/release automation for the `v0.1.0` public preview.

**Architecture:** Keep the existing SwiftPM/AppKit application and read-only SMC monitoring path. Remove every in-process SMC write/control entry point from the shipping target, build one arm64+x86_64 app bundle, verify it before packaging, and publish an ad-hoc-signed DMG as a GitHub pre-release. GitHub account changes are bounded: switch from `eucmaz` to `eyupucmaz` only for owner-scoped writes, then restore and prove `eucmaz` is active.

**Tech Stack:** Swift 5.9 language mode, SwiftPM, AppKit/SwiftUI, XCTest, Bash, `actool`, `codesign`, `lipo`, `hdiutil`, GitHub Actions, GitHub CLI.

**Spec:** [`docs/superpowers/specs/2026-09-04-public-preview-release-design.md`](../specs/2026-09-04-public-preview-release-design.md)

## Global Constraints

- Do not publish fan control in `v0.1.0`; fan RPM and temperature reads remain.
- Do not perform an SMC write in local tests, CI, packaging, or release verification.
- Do not force-push, replace an existing release tag, print authentication tokens, or leave `eyupucmaz` active after a GitHub write.
- Preserve the source `Info.plist`; build scripts may modify only the copy staged inside `dist/MacStats.app`.
- The initial artifact is ad-hoc signed and not notarized. Documentation must describe Gatekeeper behavior plainly.
- Every task ends with its focused verification. Do not proceed past a failing check.
- Before claiming completion, invoke `superpowers:verification-before-completion` and run the final commands in Task 10 from a clean checkout.

## File Map

**Modify**

- `Sources/MacStats/StatsEngine.swift` — normalize non-finite timer intervals.
- `Tests/MacStatsTests/StatsEngineTests.swift` — regression tests for interval normalization.
- `Sources/MacStats/System/SMC.swift` — retain reads and decoding; remove all write commands, state, encoding, and helpers.
- `Sources/MacStats/AppDelegate.swift` — remove `FanController` lifecycle and environment injection.
- `Sources/MacStats/Views/StatsView.swift` — retain fan RPM display; remove fan-control UI.
- `Sources/MacStats/Views/SettingsView.swift` — remove fan-control status/preferences; retain display preferences.
- `Info.plist` — set source version to `0.1.0` and build number to `1`.
- `Scripts/build-app.sh` — build/stage/sign a Universal 2 release deterministically.
- `Makefile` — expose app, DMG, and release-verification targets.
- `.gitignore` — keep generated release artifacts out of Git.
- `README.md` — public product/install/build/privacy/limitations documentation.
- `LICENSE` — verify the existing MIT text and copyright attribution; change only if inaccurate.
- `docs/superpowers/specs/2026-09-03-macstats-design.md` — mark historical design as superseded.

**Delete**

- `Sources/MacStats/FanController.swift` — unsafe in-process fan-write implementation.
- `Tests/MacStatsTests/FanControllerTests.swift` — tests that can reach real SMC writes.

**Create**

- `Scripts/check-monitoring-only.sh` — fail if fan-write APIs return to the shipping sources.
- `Scripts/verify-app.sh` — validate bundle metadata, resources, architectures, and signature.
- `Scripts/package-dmg.sh` — create the versioned DMG and SHA-256 sidecar.
- `Scripts/verify-release.sh` — mount the DMG and re-run app/artifact validation with cleanup traps.
- `.github/workflows/ci.yml` — read-only PR/main verification.
- `.github/workflows/release.yml` — semantic-tag/manual pre-release publication.
- `.github/ISSUE_TEMPLATE/bug_report.yml`
- `.github/ISSUE_TEMPLATE/feature_request.yml`
- `.github/ISSUE_TEMPLATE/config.yml`
- `.github/pull_request_template.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `CODE_OF_CONDUCT.md`
- `docs/FAN_CONTROL.md`

---

## Task 1: Create the Isolated Release Worktree and Establish the Baseline

**Files:**

- Verify: `.gitignore`
- Worktree: `.worktrees/release-v0.1.0`
- Branch: `release/v0.1.0`

- [ ] **Step 1: Invoke the worktree skill**

Read and follow `superpowers:using-git-worktrees` before executing the remaining steps in this task.

- [ ] **Step 2: Prove the local repository is clean and the worktree directory is ignored**

Run from `/Users/eyup/Code/MacStats`:

```bash
git status --short
git check-ignore -q .worktrees
```

Expected: the first command prints nothing and the second exits `0`.

- [ ] **Step 3: Create the isolated branch/worktree**

```bash
git worktree add .worktrees/release-v0.1.0 -b release/v0.1.0 main
cd .worktrees/release-v0.1.0
```

Expected: Git reports a new branch based on `main`; all implementation commands below run inside this worktree.

- [ ] **Step 4: Capture the baseline without touching fan control**

```bash
swift test
for script in Scripts/*.sh; do bash -n "$script"; done
git status --short
```

Expected: 68 tests pass, Bash syntax passes, and the worktree is clean.

---

## Task 2: Make Sampling Intervals Total and Timer-Safe

**Files:**

- Modify: `Tests/MacStatsTests/StatsEngineTests.swift`
- Modify: `Sources/MacStats/StatsEngine.swift`

- [ ] **Step 1: Invoke test-driven development**

Read and follow `superpowers:test-driven-development` for this task.

- [ ] **Step 2: Write the failing normalization tests**

Add these focused tests under `// MARK: - Update interval`:

```swift
func testNormalizedUpdateIntervalUsesOneSecondForNonFiniteInput() {
    XCTAssertEqual(StatsEngine.normalizedUpdateInterval(.nan), 1.0)
    XCTAssertEqual(StatsEngine.normalizedUpdateInterval(.infinity), 1.0)
    XCTAssertEqual(StatsEngine.normalizedUpdateInterval(-.infinity), 1.0)
}

func testNormalizedUpdateIntervalClampsFiniteInput() {
    XCTAssertEqual(StatsEngine.normalizedUpdateInterval(-100), 0.5)
    XCTAssertEqual(StatsEngine.normalizedUpdateInterval(10), 10)
    XCTAssertEqual(StatsEngine.normalizedUpdateInterval(1e9), 60)
}
```

- [ ] **Step 3: Run the focused test and observe RED**

```bash
swift test --filter StatsEngineTests/testNormalizedUpdateInterval
```

Expected: compilation fails because `StatsEngine.normalizedUpdateInterval` does not exist.

- [ ] **Step 4: Implement the smallest safe normalizer**

Add to `StatsEngine` and route `setUpdateInterval(_:)` through it:

```swift
static func normalizedUpdateInterval(_ seconds: Double) -> Double {
    guard seconds.isFinite else { return 1.0 }
    return min(max(seconds, 0.5), 60.0)
}

func setUpdateInterval(_ seconds: Double) {
    let clamped = Self.normalizedUpdateInterval(seconds)
    // existing locked timer restart follows
}
```

This guarantees `Int(updateInterval * 1000)` receives a finite value in the safe 500...60,000 ms range.

- [ ] **Step 5: Run focused and full tests and observe GREEN**

```bash
swift test --filter StatsEngineTests/testNormalizedUpdateInterval
swift test
```

Expected: both new tests and the full suite pass.

- [ ] **Step 6: Commit the timer fix**

```bash
git add Sources/MacStats/StatsEngine.swift Tests/MacStatsTests/StatsEngineTests.swift
git commit -m "fix: handle non-finite sampling intervals"
```

---

## Task 3: Convert the Shipping App to Read-Only Fan Monitoring

**Files:**

- Create: `Scripts/check-monitoring-only.sh`
- Delete: `Sources/MacStats/FanController.swift`
- Delete: `Tests/MacStatsTests/FanControllerTests.swift`
- Modify: `Sources/MacStats/System/SMC.swift`
- Modify: `Sources/MacStats/AppDelegate.swift`
- Modify: `Sources/MacStats/Views/StatsView.swift`
- Modify: `Sources/MacStats/Views/SettingsView.swift`
- Verify: `Tests/MacStatsTests/StatsEngineTests.swift`
- Verify: `Tests/MacStatsTests/MenuBarRendererTests.swift`

- [ ] **Step 1: Add a release safety check and observe it fail**

Create `Scripts/check-monitoring-only.sh`:

```bash
#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly pattern='cmdWriteBytes|writeFanTarget|restoreAutoFanControl|manualModeKey|FanController'

if /usr/bin/grep -R -n -E "${pattern}" "${repo_root}/Sources/MacStats"; then
    printf 'error: shipping sources contain an SMC fan-write/control path\n' >&2
    exit 1
fi

printf 'Monitoring-only safety check passed.\n'
```

Then run:

```bash
chmod +x Scripts/check-monitoring-only.sh
bash Scripts/check-monitoring-only.sh
```

Expected: non-zero exit with matches in `FanController.swift`, `SMC.swift`, `AppDelegate.swift`, and views.

- [ ] **Step 2: Remove the fan controller from application lifecycle and UI composition**

In `AppDelegate.swift`:

- remove `FanController.shared.refresh()` startup behavior;
- remove shutdown-time `restoreAutomaticControl()`;
- remove `.environmentObject(FanController.shared)` from both root views.

In `StatsView.swift`:

- remove `@EnvironmentObject var fan: FanController`;
- remove the manual/custom/automatic fan controls and their bindings;
- keep the read-only `stats.fanRPM` monitoring card.

In `SettingsView.swift`:

- remove the fan environment object, control section, status text, and refresh call;
- keep menu-bar display toggles for RPM and temperature;
- update the preview so it no longer injects `FanController`.

Delete `Sources/MacStats/FanController.swift` and `Tests/MacStatsTests/FanControllerTests.swift`.

- [ ] **Step 3: Remove every SMC write primitive**

In `Sources/MacStats/System/SMC.swift`, remove:

- `cmdWriteBytes`;
- `lastWriteError` and `setWriteError`;
- `manualModeKey(index:)`, `writeFanTarget(_:index:)`, and `restoreAutoFanControl(index:)`;
- private `write(_:value:)`;
- encoding-only `encode`, `bigEndianPayload`, and `tuple(from:)` helpers;
- write-key descriptions and comments that claim writes are supported.

Retain read-only fan RPM/min/max/target diagnostics, temperature probes, decoding, `describe(...)`, and the exact 80-byte SMC layout.

- [ ] **Step 4: Prove the shipping source has no control path**

```bash
bash Scripts/check-monitoring-only.sh
if rg -n 'F[0-9].*(Md|md)|cmdWriteBytes|writeFanTarget|restoreAutoFanControl|FanController' Sources/MacStats; then
  exit 1
fi
```

Expected: the script passes and `rg` prints no matches.

- [ ] **Step 5: Prove monitoring still builds and its hardware-independent contracts pass**

```bash
swift test --filter StatsEngineTests/testFanRPMIsZeroWhenNoFanIsAvailable
swift test --filter StatsEngineTests/testTemperatureIsPlausibleOrReportedUnavailable
swift test --filter MenuBarRendererTests
swift test
```

Expected: every command passes; no command attempts an SMC write.

- [ ] **Step 6: Commit the monitoring-only boundary**

```bash
git add -A Sources Tests Scripts/check-monitoring-only.sh
git commit -m "refactor: make fan monitoring read-only"
```

---

## Task 4: Produce and Verify a Versioned Universal App Bundle

**Files:**

- Modify: `Info.plist`
- Modify: `Scripts/build-app.sh`
- Create: `Scripts/verify-app.sh`
- Modify: `Makefile`
- Modify: `.gitignore`

- [ ] **Step 1: Set the source release version**

Set these values in `Info.plist`:

```xml
<key>CFBundleShortVersionString</key>
<string>0.1.0</string>
<key>CFBundleVersion</key>
<string>1</string>
```

Do not change `CFBundleIdentifier` (`com.eyupucmaz.MacStats`) or the macOS 13 minimum.

- [ ] **Step 2: Add an app verification script before changing the build**

Create `Scripts/verify-app.sh` with this command interface:

```text
bash Scripts/verify-app.sh <path-to-MacStats.app> <expected-version> <expected-build> [expected-archs]
```

The optional architecture string defaults to `arm64 x86_64`. The script must fail unless all of these hold:

- `Contents/Info.plist` passes `plutil -lint`;
- bundle ID is exactly `com.eyupucmaz.MacStats`;
- short/build versions equal the supplied values;
- `Contents/MacOS/MacStats` is executable;
- `Contents/Resources/MacStats_MacStats.bundle` exists;
- `Contents/Resources/Assets.car` and `Contents/Resources/AppIcon.icns` exist;
- `lipo -archs` contains exactly the requested architecture set;
- `codesign --verify --strict --deep --verbose=2` passes;
- `codesign -d --entitlements :-` does not reveal unexpected entitlements.

Run it against the existing single-architecture app:

```bash
bash Scripts/build-app.sh
bash Scripts/verify-app.sh dist/MacStats.app 0.1.0 1
```

Expected: verification fails on architecture and/or old staged version behavior, proving the new release gate is active.

- [ ] **Step 3: Refactor `build-app.sh` around explicit release inputs**

Support these environment variables:

```bash
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)}"
ARCHS="${ARCHS:-arm64 x86_64}"
RELEASE_STRICT="${RELEASE_STRICT:-0}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-none}"
```

Implementation requirements:

- validate `APP_VERSION` against `^[0-9]+\.[0-9]+\.[0-9]+$`;
- validate `BUILD_NUMBER` as a positive integer;
- allow `ARCHS` only as `arm64 x86_64`, `arm64`, or `x86_64`;
- compile Universal 2 with `swift build -c release --arch arm64 --arch x86_64`;
- use `.build/apple/Products/Release/MacStats` and its resource bundle for multi-arch output;
- continue supporting explicit single-arch local builds using SwiftPM's normal triple output resolved with `swift build --show-bin-path`;
- modify only `dist/MacStats.app/Contents/Info.plist` with `/usr/libexec/PlistBuddy`;
- make missing `actool`, assets, icon, or SwiftPM resource bundle fatal when `RELEASE_STRICT=1`;
- sign with `codesign --force --deep --options runtime --sign "${CODE_SIGN_IDENTITY}"`; add `--timestamp` only when `CODE_SIGN_TIMESTAMP=1`;
- call `Scripts/verify-app.sh` before reporting success.

- [ ] **Step 4: Add Make targets and ignore generated artifacts**

Add:

```make
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1
DMG := dist/MacStats-$(VERSION)-universal.dmg

app:
	APP_VERSION=$(VERSION) BUILD_NUMBER=$(BUILD_NUMBER) RELEASE_STRICT=1 bash Scripts/build-app.sh

verify-app:
	bash Scripts/verify-app.sh dist/MacStats.app $(VERSION) $(BUILD_NUMBER)
```

Add `verify-app` to `.PHONY`. Ensure `.gitignore` covers `.build/`, `dist/`, `.DS_Store`, and `.worktrees/` without weakening existing entries.

- [ ] **Step 5: Build and verify the Universal app**

```bash
for script in Scripts/*.sh; do bash -n "$script"; done
make app VERSION=0.1.0 BUILD_NUMBER=1
make verify-app VERSION=0.1.0 BUILD_NUMBER=1
lipo -archs dist/MacStats.app/Contents/MacOS/MacStats
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/MacStats.app/Contents/Info.plist
git diff --exit-code -- Info.plist
```

Expected: architectures are `x86_64 arm64` in either order, staged version is `0.1.0`, and source `Info.plist` remains unchanged by the build.

- [ ] **Step 6: Commit Universal app packaging**

```bash
git add Info.plist Scripts/build-app.sh Scripts/verify-app.sh Makefile .gitignore
git commit -m "build: add verified universal app packaging"
```

---

## Task 5: Package and Mount-Verify the DMG

**Files:**

- Create: `Scripts/package-dmg.sh`
- Create: `Scripts/verify-release.sh`
- Modify: `Makefile`

- [ ] **Step 1: Define the packaging interface and negative checks**

`Scripts/package-dmg.sh` accepts a semantic version as its only argument:

```text
bash Scripts/package-dmg.sh 0.1.0
```

Before implementing it, run these intended-invalid calls after creating the argument-validation skeleton:

```bash
! bash Scripts/package-dmg.sh
! bash Scripts/package-dmg.sh latest
```

Expected: both fail with a concise usage/version error and create no artifact.

- [ ] **Step 2: Implement recoverable DMG staging**

The script must:

- require `dist/MacStats.app` and validate it with `Scripts/verify-app.sh`;
- derive the expected build number from the staged app plist;
- create a staging directory with `mktemp -d`;
- install `MacStats.app` and an `Applications -> /Applications` symlink in that staging directory;
- install a cleanup trap for every temporary directory and mounted image;
- create `dist/MacStats-<version>-universal.dmg` with `hdiutil create -format UDZO -fs HFS+`;
- write a portable SHA-256 sidecar using:

```bash
(
  cd dist
  shasum -a 256 "MacStats-${version}-universal.dmg" \
    > "MacStats-${version}-universal.dmg.sha256"
)
```

The checksum file must contain only the artifact filename, never an absolute local path.

- [ ] **Step 3: Implement mounted release verification**

`Scripts/verify-release.sh` accepts version and optional build number:

```text
bash Scripts/verify-release.sh 0.1.0 [1]
```

It must:

- check the DMG and sidecar filenames;
- verify `shasum -a 256 -c` from inside `dist/`;
- attach with `hdiutil attach -readonly -nobrowse -plist`;
- capture the exact device and mount point from the returned plist;
- trap cleanup and detach the exact device even when verification fails;
- assert `MacStats.app` and the `/Applications` symlink exist at the mounted root;
- run `verify-app.sh` against the mounted app;
- assert the mounted app has no quarantine attribute added by packaging.

- [ ] **Step 4: Wire Make targets**

```make
dmg: app
	bash Scripts/package-dmg.sh $(VERSION)

verify-release:
	bash Scripts/verify-release.sh $(VERSION) $(BUILD_NUMBER)
```

Add `dmg` and `verify-release` to `.PHONY` and help output.

- [ ] **Step 5: Build, mount, verify, and prove cleanup**

```bash
for script in Scripts/*.sh; do bash -n "$script"; done
make dmg VERSION=0.1.0 BUILD_NUMBER=1
make verify-release VERSION=0.1.0 BUILD_NUMBER=1
shasum -a 256 -c dist/MacStats-0.1.0-universal.dmg.sha256
hdiutil info | rg 'MacStats-0.1.0-universal' && exit 1 || true
```

Expected: DMG verification passes and no MacStats image remains mounted.

- [ ] **Step 6: Commit DMG packaging**

```bash
git add Scripts/package-dmg.sh Scripts/verify-release.sh Makefile
git commit -m "build: add verified DMG packaging"
```

---

## Task 6: Add Least-Privilege Pull Request and Main-Branch CI

**Files:**

- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow with explicit permissions and concurrency**

Use:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

- [ ] **Step 2: Test both current macOS architectures**

Create a matrix job over:

```yaml
strategy:
  fail-fast: false
  matrix:
    runner: [macos-15, macos-15-intel]
runs-on: ${{ matrix.runner }}
```

Checkout must be immutable:

```yaml
- uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
```

Run, in order:

```bash
bash Scripts/check-monitoring-only.sh
for script in Scripts/*.sh; do bash -n "$script"; done
bash Tests/ReleaseSafetyTests.sh
swift test
```

No job receives secrets or invokes a command capable of SMC writes.

- [ ] **Step 3: Add one Universal packaging job**

On `macos-15`, after tests:

```bash
APP_VERSION=0.1.0 BUILD_NUMBER="${GITHUB_RUN_NUMBER}" RELEASE_STRICT=1 bash Scripts/build-app.sh
bash Scripts/verify-app.sh dist/MacStats.app 0.1.0 "${GITHUB_RUN_NUMBER}"
```

Upload the `.app` only as a short-lived CI diagnostic using:

```yaml
- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
  with:
    name: MacStats-universal-app
    path: dist/MacStats.app
    if-no-files-found: error
    retention-days: 7
```

- [ ] **Step 4: Perform local static validation**

```bash
ruby - <<'RUBY'
require 'yaml'
data = YAML.safe_load(File.read('.github/workflows/ci.yml'), aliases: true)
raise 'unexpected permissions' unless data['permissions'] == {'contents' => 'read'}
raise 'concurrency cancellation is disabled' unless data.dig('concurrency', 'cancel-in-progress') == true
puts 'CI workflow structure OK'
RUBY
rg -n 'secrets\.|writeFanTarget|restoreAutoFanControl|cmdWriteBytes' .github/workflows/ci.yml && exit 1 || true
```

- [ ] **Step 5: Commit CI**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: validate macOS builds"
```

---

## Task 7: Automate Immutable Public Preview Releases

**Files:**

- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Define tightly scoped triggers and inputs**

```yaml
name: Release

on:
  push:
    tags: ['v*.*.*']
  workflow_dispatch:
    inputs:
      tag:
        description: Existing semantic tag to release, for example v0.1.0
        required: true
        type: string

permissions:
  contents: write

concurrency:
  group: release-${{ github.event.inputs.tag || github.ref_name }}
  cancel-in-progress: false
```

- [ ] **Step 2: Validate and check out an existing immutable semantic tag**

Set:

```yaml
env:
  RELEASE_TAG: ${{ github.event.inputs.tag || github.ref_name }}
```

Checkout the explicit ref with the pinned checkout SHA and `fetch-depth: 0`. Validate in Bash:

```bash
[[ "${RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
git rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}"
test "$(git rev-parse HEAD)" = "$(git rev-list -n 1 "${RELEASE_TAG}")"
```

For `workflow_dispatch`, this deliberately refuses to create a tag from a branch.

- [ ] **Step 3: Run the same safety and test gates as CI**

```bash
bash Scripts/check-monitoring-only.sh
for script in Scripts/*.sh; do bash -n "$script"; done
swift test
```

- [ ] **Step 4: Build and verify versioned artifacts**

```bash
version="${RELEASE_TAG#v}"
APP_VERSION="${version}" BUILD_NUMBER="${GITHUB_RUN_NUMBER}" RELEASE_STRICT=1 \
  bash Scripts/build-app.sh
bash Scripts/package-dmg.sh "${version}"
bash Scripts/verify-release.sh "${version}" "${GITHUB_RUN_NUMBER}"
```

- [ ] **Step 5: Fail instead of overwriting an existing release**

Give the lookup step `GH_TOKEN: ${{ github.token }}`. First prove the token can
access `repos/${GITHUB_REPOSITORY}`, then query
`repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}` with response headers.
Treat only a confirmed HTTP 404 as absence. An existing release, authentication
failure, network failure, or any other API response must stop publication.

- [ ] **Step 6: Publish a pre-release with exactly two assets**

Use the immutable release action:

```yaml
- uses: softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65 # v2
  with:
    token: ${{ github.token }}
    tag_name: ${{ env.RELEASE_TAG }}
    name: MacStats ${{ env.RELEASE_TAG }} Public Preview
    prerelease: true
    generate_release_notes: true
    body: |
      MacStats v0.1.0 Public Preview is monitoring-only.
      This build is ad-hoc signed and is not notarized. Drag `MacStats.app`
      to Applications, follow the documented Gatekeeper steps, and verify
      the downloaded checksum with `shasum -a 256 -c` before opening it.
    overwrite_files: false
    fail_on_unmatched_files: true
    files: |
      dist/MacStats-*-universal.dmg
      dist/MacStats-*-universal.dmg.sha256
```

- [ ] **Step 7: Validate workflow structure and permissions locally**

```bash
bash Tests/ReleaseSafetyTests.sh
rg -n 'contents: write|prerelease: true|generate_release_notes: true|overwrite_files: false|fail_on_unmatched_files: true' .github/workflows/release.yml
rg -n 'secrets\.|writeFanTarget|restoreAutoFanControl|cmdWriteBytes' .github/workflows/release.yml && exit 1 || true
```

Expected: required release controls are found; forbidden patterns are absent.

- [ ] **Step 8: Commit release automation**

```bash
git add .github/workflows/release.yml
git commit -m "ci: automate preview releases"
```

---

## Task 8: Add the Open-Source Product and Community Surface

**Files:**

- Modify: `README.md`
- Verify/Modify: `LICENSE`
- Create: `CHANGELOG.md`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `docs/FAN_CONTROL.md`
- Modify: `docs/superpowers/specs/2026-09-03-macstats-design.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/pull_request_template.md`

- [ ] **Step 1: Rewrite README around the actual public preview**

Use concise English and include:

- product summary and macOS 13+ requirement;
- current read-only metrics, explicitly including fan RPM and temperature when hardware exposes them;
- download link to `https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0`;
- DMG install steps: drag to Applications, then Control-click → Open or Privacy & Security → Open Anyway for this unnotarized preview;
- a checksum verification example using `shasum -a 256 -c`;
- privacy statement: local system metrics, no accounts, no telemetry, no network data upload by the app;
- limitations: hardware/SMC availability varies; fan control is not included; ad-hoc signature is not notarization;
- build/test/package commands from the scripts added above;
- contribution, security, license, and roadmap links;
- a maintainer/site link to `https://eyupucmaz.dev`.

Do not claim Intel fan-control support, a fanless Mac model list, notarization, auto-update, or universal hardware support beyond what CI verifies.

- [ ] **Step 2: Add release history and contributor guidance**

`CHANGELOG.md` follows Keep a Changelog headings and contains:

```markdown
## [Unreleased]

## [0.1.0] - 2026-09-04
### Added
- Read-only macOS system monitoring in a menu bar app.
- Universal 2 DMG packaging and automated verification.
```

Include the GitHub compare/release links at the bottom.

`CONTRIBUTING.md` must require:

- macOS 13+, Xcode/Swift toolchain compatible with Swift tools 5.9;
- `swift test`, monitoring-only check, and release script syntax checks before PRs;
- no tests or product code that writes to SMC;
- focused commits and an issue before broad behavioral changes;
- acceptance of the code of conduct.

- [ ] **Step 3: Add responsible security and conduct files**

`SECURITY.md`:

- lists `0.1.x` as preview-supported;
- directs confidential reports to GitHub Private Vulnerability Reporting at `https://github.com/eyupucmaz/MacStats/security/advisories/new`;
- asks reporters not to open public issues for exploitable findings;
- promises acknowledgement/updates without inventing fixed response deadlines.

`CODE_OF_CONDUCT.md` uses Contributor Covenant 2.1, preserving its attribution and link, with `https://eyupucmaz.dev` as the maintainer contact surface.

Verify the existing MIT `LICENSE`; retain it if it is complete and attributed to Eyup Ucmaz.

- [ ] **Step 4: Document fan-control feasibility as a separate privileged architecture**

`docs/FAN_CONTROL.md` must explain:

- why `v0.1.0` is monitoring-only: partial writes, races, crashes, or SIGKILL can leave hardware in an unsafe/manual state;
- Apple does not provide a stable public high-level fan-control API;
- future control requires a separately installed, least-privileged helper using `SMAppService`, explicit administrator approval, authenticated IPC/audit-token validation, strict RPM/model allowlists, a watchdog/lease, and unconditional automatic-mode restoration;
- suggested phases: read-only key mapping, helper prototype, fail-safe tests on supported devices, signed/notarized opt-in preview;
- explicit non-goal: silently escalating privileges or copying reverse-engineered key mappings without per-model validation.

Use and link these primary sources:

- Apple notarization: `https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution`
- Apple `SMAppService`: `https://developer.apple.com/documentation/servicemanagement/smappservice`
- Apple helper-tool/privacy guidance: `https://developer.apple.com/videos/play/wwdc2022/10096/`
- Apple least-privilege guidance: `https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/AccessControl.html`

Label community SMC research as reverse engineering, not an Apple contract.

- [ ] **Step 5: Add structured issue forms and PR checklist**

Bug form fields: macOS version, Mac model/architecture, MacStats version, observed behavior, expected behavior, reproduction steps, and logs with a privacy warning.

Feature form fields: problem, proposed behavior, alternatives, and hardware impact. Its description must say fan-control requests remain roadmap discussions.

PR template checklist:

- tests pass;
- monitoring-only safety script passes;
- docs/changelog updated where applicable;
- no SMC write path or secret added;
- screenshots included for UI changes.

Disable blank issues and link security reports to Private Vulnerability Reporting.

- [ ] **Step 6: Mark the earlier design as historical**

At the top of `docs/superpowers/specs/2026-09-03-macstats-design.md`, add a visible status note linking to the approved 2026-09-04 public-preview spec. State that fan-control portions are historical and are not release requirements.

- [ ] **Step 7: Verify documentation claims against the repository**

```bash
rg -n 'eyupucmaz|eyupucmaz\.dev|0\.1\.0|monitoring-only|notariz' README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md docs/FAN_CONTROL.md
rg -n 'Fan Control|Manual Mode|Custom RPM|writeFanTarget|restoreAutoFanControl' README.md Sources/MacStats && exit 1 || true
test -f LICENSE
test -f CODE_OF_CONDUCT.md
test -f .github/ISSUE_TEMPLATE/bug_report.yml
test -f .github/pull_request_template.md
```

Expected: ownership/version/disclosure text is present; released UI/README contain no fan-control claim.

- [ ] **Step 8: Commit the public project surface**

```bash
git add README.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md docs .github/ISSUE_TEMPLATE .github/pull_request_template.md
git commit -m "docs: prepare MacStats for open source"
```

---

## Task 9: Run a Pre-Publication Review and Merge the Release Branch Locally

**Files:** All changed files.

- [ ] **Step 1: Invoke code review**

Use `superpowers:requesting-code-review` with the diff from `main...release/v0.1.0`. The review must explicitly cover:

- no reachable SMC write path;
- timer normalization correctness;
- packaging cleanup and quoting;
- GitHub Actions permissions/tag immutability;
- docs matching actual behavior.

- [ ] **Step 2: Resolve every Critical or Important finding**

Use `superpowers:receiving-code-review` before applying review feedback. Re-run the focused verification for each changed area and commit each coherent fix.

- [ ] **Step 3: Run the complete clean release gate**

```bash
git status --short
bash Scripts/check-monitoring-only.sh
for script in Scripts/*.sh; do bash -n "$script"; done
swift test
make clean
make dmg VERSION=0.1.0 BUILD_NUMBER=1
make verify-release VERSION=0.1.0 BUILD_NUMBER=1
git diff --exit-code
git status --short
```

Expected: clean before and after, all tests pass, and the DMG verifies after a fresh clean build.

- [ ] **Step 4: Fast-forward `main` from the primary checkout**

From `/Users/eyup/Code/MacStats`:

```bash
git status --short
git merge --ff-only release/v0.1.0
git log --oneline --decorate -8
```

Expected: clean primary checkout and a fast-forward only; do not merge if either condition fails.

- [ ] **Step 5: Re-run the minimum release proof on `main`**

```bash
make clean
make dmg VERSION=0.1.0 BUILD_NUMBER=1
bash Scripts/check-monitoring-only.sh
make verify-release VERSION=0.1.0 BUILD_NUMBER=1
git diff --exit-code
```

Expected: main passes without rebuilding or modifying tracked files.

---

## Task 10: Publish to `eyupucmaz`, Release `v0.1.0`, and Restore `eucmaz`

**Files/Remote:**

- Create: GitHub repository `eyupucmaz/MacStats`
- Push: `main`
- Create/push: annotated tag `v0.1.0`
- Create: GitHub pre-release through Actions
- Restore: active GitHub CLI account `eucmaz`

- [ ] **Step 1: Invoke final verification before any remote write**

Read and follow `superpowers:verification-before-completion`. Confirm:

```bash
git status --short
git branch --show-current
git remote -v
gh auth status
gh repo view eyupucmaz/MacStats >/dev/null 2>&1; test $? -eq 1
```

Expected: clean `main`, no conflicting remote, active account is `eucmaz`, and the target repository does not already exist. If the repository now exists, stop and inspect ownership/content rather than overwriting it.

- [ ] **Step 2: Create and push the public repository in a bounded account switch**

Use a subshell and trap so restoration runs on success or failure:

```bash
(
  restore_account() { gh auth switch -u eucmaz >/dev/null; }
  trap restore_account EXIT INT TERM

  gh auth switch -u eyupucmaz
  test "$(gh api user --jq .login)" = "eyupucmaz"
  gh repo create eyupucmaz/MacStats \
    --public \
    --source=. \
    --remote=origin \
    --push \
    --description "A lightweight, privacy-friendly macOS menu bar system monitor." \
    --homepage "https://eyupucmaz.dev"
  gh repo edit eyupucmaz/MacStats \
    --add-topic macos \
    --add-topic swift \
    --add-topic menu-bar \
    --add-topic system-monitor
  gh api --method PUT repos/eyupucmaz/MacStats/private-vulnerability-reporting
)

test "$(gh api user --jq .login)" = "eucmaz"
```

Expected: the repository is public and `eucmaz` is active immediately after the subshell. If Private Vulnerability Reporting is unavailable for the repository, record that limitation and keep the `SECURITY.md` reporting link only after verifying GitHub offers it; otherwise revise the link before tagging.

- [ ] **Step 3: Wait for and inspect main-branch CI**

```bash
gh run list --repo eyupucmaz/MacStats --workflow CI --branch main --limit 1
run_id="$(gh run list --repo eyupucmaz/MacStats --workflow CI --branch main --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "${run_id}" --repo eyupucmaz/MacStats --exit-status
```

Expected: CI succeeds. Do not tag while CI is red or missing.

- [ ] **Step 4: Create the annotated release tag without rewriting any existing tag**

```bash
test -z "$(git tag -l v0.1.0)"
git tag -a v0.1.0 -m "MacStats v0.1.0 Public Preview"

(
  restore_account() { gh auth switch -u eucmaz >/dev/null; }
  trap restore_account EXIT INT TERM

  gh auth switch -u eyupucmaz
  test "$(gh api user --jq .login)" = "eyupucmaz"
  git push origin v0.1.0
)

test "$(gh api user --jq .login)" = "eucmaz"
```

Expected: the new tag is pushed exactly once and the active account is restored.

- [ ] **Step 5: Wait for the release workflow**

```bash
release_run_id="$(gh run list --repo eyupucmaz/MacStats --workflow Release --limit 1 --json databaseId,headBranch --jq '.[] | select(.headBranch == "v0.1.0") | .databaseId' | head -n 1)"
test -n "${release_run_id}"
gh run watch "${release_run_id}" --repo eyupucmaz/MacStats --exit-status
```

Expected: release automation completes successfully. On failure, preserve the failed run and tag; fix forward with a new version instead of replacing `v0.1.0`.

- [ ] **Step 6: Verify the public repository and release contract**

```bash
gh repo view eyupucmaz/MacStats --json nameWithOwner,visibility,homepageUrl,defaultBranchRef \
  --jq '{owner: .nameWithOwner, visibility, homepage: .homepageUrl, branch: .defaultBranchRef.name}'
gh release view v0.1.0 --repo eyupucmaz/MacStats \
  --json isPrerelease,name,tagName,url \
  --jq '{tag: .tagName, name, prerelease: .isPrerelease, url}'
gh release view v0.1.0 --repo eyupucmaz/MacStats --json assets \
  --jq '.assets[].name'
test "$(gh api user --jq .login)" = "eucmaz"
git status --short
```

Expected:

- owner is `eyupucmaz/MacStats`;
- visibility is `PUBLIC`, homepage is `https://eyupucmaz.dev`, default branch is `main`;
- release is a pre-release named `MacStats v0.1.0 Public Preview`;
- assets are exactly `MacStats-0.1.0-universal.dmg` and `MacStats-0.1.0-universal.dmg.sha256`;
- active GitHub account is `eucmaz`;
- local worktree is clean.

- [ ] **Step 7: Report the release and fan-control boundary**

Return the repository URL, release URL, exact asset names, CI status, verification summary, and explicit proof that `eucmaz` is active again. Summarize fan control as a future privileged-helper milestone and link `docs/FAN_CONTROL.md`; do not imply that `v0.1.0` controls fans.
