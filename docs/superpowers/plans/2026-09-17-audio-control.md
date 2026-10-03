# MacStats Audio Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Audio tab that safely controls system input/output devices on macOS 13 and provides an opt-in per-application mixer on macOS 14.2+.

**Architecture:** A Core Audio facade isolates C APIs from SwiftUI and tests. `AudioDeviceService` owns ordinary device state and changes; `AppMixerService` is availability- and permission-gated, owns an ephemeral process-tap/aggregate-device session, and always tears it down. The popover becomes a tab shell that keeps the existing system-stat view intact.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, SwiftUI, Combine, CoreAudio, XCTest.

**Spec:** [`docs/superpowers/specs/2026-09-17-audio-control-design.md`](../specs/2026-09-17-audio-control-design.md)

**Status:** Implemented; hardware verification pending (see #3–#5)

## Global Constraints

- Keep `Package.swift` at macOS 13 and link `CoreAudio`.
- Input/output device selection, master volume, and mute work on macOS 13+.
- Application mixing is unavailable below macOS 14.2 and must not request audio-capture permission there.
- Treat a browser as one process-level source; do not claim tab-level control.
- Never record, persist, upload, or start capturing audio at launch or while the Audio tab is idle.
- Per-app mixer state is ephemeral and must stop on tab close, output-device change, permission loss, and application termination.
- Every Core Audio mutation checks property support and writability, then re-reads the property before publishing it.
- The real-time audio callback does not allocate, log, call SwiftUI, or access `UserDefaults`.
- Unit tests use fakes and must not query a physical device or capture system audio.
- Do not commit, push, or publish without separate user authorization.

---

## File map

**Create**

- `Sources/MacStats/Audio/AudioModels.swift` — UI-safe audio device, control-state, process, capability, and error models.
- `Sources/MacStats/Audio/AudioHardwareClient.swift` — protocol and Core Audio adapter for device/default-device/property operations.
- `Sources/MacStats/Audio/AudioDeviceService.swift` — observable macOS 13+ device state and safe mutations.
- `Sources/MacStats/Audio/AppMixerService.swift` — macOS 14.2+ capability, permission, process discovery, and session lifecycle.
- `Sources/MacStats/Audio/AppMixerSession.swift` — transient Core Audio tap/aggregate-resource ownership and idempotent teardown.
- `Sources/MacStats/Views/AudioTab.swift` — device controls, capability explanations, app-mixer states, and process rows.
- `Tests/MacStatsTests/AudioDeviceServiceTests.swift` — fake-hardware unit tests for device controls and errors.
- `Tests/MacStatsTests/AppMixerServiceTests.swift` — capability, permission, gain/mute, and cleanup unit tests.

**Modify**

- `Package.swift` — link CoreAudio.
- `Sources/MacStats/AppDelegate.swift` — create services once, inject them into the popover, and stop the mixer during teardown.
- `Sources/MacStats/Views/StatsView.swift` — retain existing system-stat UI as the System tab content and host tabs.
- `README.md` and `docs/guide.html` — describe local-only Audio controls, OS requirements, and limits after functionality is verified.

## Interfaces introduced by this plan

```swift
enum AudioDirection: Sendable { case input, output }

struct AudioDevice: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let name: String
    let directions: Set<AudioDirection>
    let supportsVolume: Bool
    let supportsMute: Bool
}

struct AudioDeviceState: Equatable, Sendable {
    var devices: [AudioDevice]
    var defaultInputID: AudioObjectID?
    var defaultOutputID: AudioObjectID?
    var outputVolume: Float?
    var outputMuted: Bool?
    var outputControlMessage: String?
}

protocol AudioHardwareClient: AnyObject {
    func readDeviceState() throws -> AudioDeviceState
    func setDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) throws
    func setOutputVolume(_ value: Float, deviceID: AudioObjectID) throws
    func setOutputMuted(_ muted: Bool, deviceID: AudioObjectID) throws
    func startObserving(_ handler: @escaping @Sendable () -> Void)
    func stopObserving()
}

@MainActor final class AudioDeviceService: ObservableObject {
    @Published private(set) var state: AudioDeviceState
    @Published private(set) var errorMessage: String?
    func refresh()
    func selectDefaultDevice(_ id: AudioObjectID, direction: AudioDirection)
    func setOutputVolume(_ value: Float)
    func setOutputMuted(_ muted: Bool)
}
```

`AppMixerService` exposes `capability`, `permissionState`, `processes`,
`isRunning`, `statusMessage`, `enable()`, `disable()`, `setGain(_:for:)`, and
`setMuted(_:for:)`. Its concrete Core Audio adapter is used only from a
`#available(macOS 14.2, *)` path; all other systems receive `.requiresMacOS142`.

### Task 1: Define testable audio models and the Core Audio boundary

**Files:**

- Create: `Sources/MacStats/Audio/AudioModels.swift`
- Create: `Sources/MacStats/Audio/AudioHardwareClient.swift`
- Test: `Tests/MacStatsTests/AudioDeviceServiceTests.swift`
- Modify: `Package.swift`

**Produces:** `AudioDirection`, `AudioDevice`, `AudioDeviceState`,
`AudioHardwareClient`, `AudioHardwareError`, and a Core Audio implementation
named `SystemAudioHardwareClient`.

- [ ] **Step 1: Add CoreAudio to the executable target linker settings**

```swift
.linkedFramework("CoreAudio"),
```

- [ ] **Step 2: Write failing model tests for directional filtering and output-control messages**

```swift
func testOutputDevicesExcludeInputOnlyDevices() {
    let input = AudioDevice(id: 1, name: "Mic", directions: [.input],
                            supportsVolume: false, supportsMute: false)
    let output = AudioDevice(id: 2, name: "Speakers", directions: [.output],
                             supportsVolume: true, supportsMute: true)
    XCTAssertEqual(AudioDevice.outputDevices(in: [input, output]), [output])
}

func testUnavailableOutputControlHasAnExplanation() {
    let state = AudioDeviceState(devices: [], defaultInputID: nil,
                                 defaultOutputID: 2, outputVolume: nil,
                                 outputMuted: nil,
                                 outputControlMessage: "Speakers does not expose a master volume control.")
    XCTAssertEqual(state.outputControlMessage,
                   "Speakers does not expose a master volume control.")
}
```

- [ ] **Step 3: Run the focused test and confirm compilation fails because the audio models do not exist**

Run: `swift test --filter AudioDeviceServiceTests`

Expected: compilation failure naming missing `AudioDevice` and `AudioDeviceState`.

- [ ] **Step 4: Implement the value models and protocol**

```swift
enum AudioDirection: Hashable, Sendable { case input, output }

extension AudioDevice {
    static func outputDevices(in devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { $0.directions.contains(.output) }
    }
}
```

Define `AudioHardwareError.unsupportedControl(String)`,
`.unwritableControl(String)`, `.deviceUnavailable`, and `.osStatus(OSStatus)`;
map them to human-readable messages in this layer, not in SwiftUI.

- [ ] **Step 5: Implement `SystemAudioHardwareClient` around Core Audio properties**

Use `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultInputDevice`,
and `kAudioHardwarePropertyDefaultOutputDevice` to enumerate/default devices.
For every output volume or mute operation, use
`AudioObjectHasProperty`, `AudioObjectIsPropertySettable`, and
`AudioObjectGetPropertyData` before `AudioObjectSetPropertyData`; re-read after
the write. Register listeners for the device list and both default-device
properties, forwarding to the supplied handler on a serial utility queue.

- [ ] **Step 6: Re-run focused tests and build**

Run: `swift test --filter AudioDeviceServiceTests && swift build`

Expected: both commands pass without accessing real audio hardware in tests.

### Task 2: Build the observable device-control service

**Files:**

- Create: `Sources/MacStats/Audio/AudioDeviceService.swift`
- Modify: `Tests/MacStatsTests/AudioDeviceServiceTests.swift`

**Consumes:** `AudioHardwareClient`, `AudioDeviceState` from Task 1.

**Produces:** an injectable `@MainActor AudioDeviceService` whose public methods
match the interface map.

- [ ] **Step 1: Extend the fake client and add failing service tests**

```swift
func testSelectingOutputWritesThenPublishesFreshState() async {
    let hardware = FakeAudioHardware(state: speakersState)
    let service = await AudioDeviceService(hardware: hardware)
    await service.selectDefaultDevice(9, direction: .output)
    XCTAssertEqual(hardware.defaultDeviceWrites, [(9, .output)])
    XCTAssertEqual(await service.state.defaultOutputID, 9)
}

func testUnsupportedVolumeLeavesValueUntouchedAndPublishesMessage() async {
    let hardware = FakeAudioHardware(error: .unsupportedControl("HDMI does not expose a master volume control."))
    let service = await AudioDeviceService(hardware: hardware)
    await service.setOutputVolume(0.25)
    XCTAssertEqual(await service.state.outputVolume, 0.8)
    XCTAssertEqual(await service.errorMessage,
                   "HDMI does not expose a master volume control.")
}
```

- [ ] **Step 2: Run the focused test and confirm failure because `AudioDeviceService` is absent**

Run: `swift test --filter AudioDeviceServiceTests`

Expected: compilation failure naming missing `AudioDeviceService`.

- [ ] **Step 3: Implement a main-actor service with an injected client**

```swift
@MainActor
final class AudioDeviceService: ObservableObject {
    @Published private(set) var state: AudioDeviceState
    @Published private(set) var errorMessage: String?

    init(hardware: AudioHardwareClient = SystemAudioHardwareClient()) {
        self.hardware = hardware
        state = .empty
        hardware.startObserving { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
}
```

Clamp volume arguments to `0...1`; when no default output exists, publish
`"No output device is currently available."` and skip the write. Every public
mutation clears a previous error, executes the client mutation, then calls
`refresh()`; failure records the mapped error and also refreshes state.

- [ ] **Step 4: Add listener and deinitialization tests**

```swift
func testHardwareChangeRefreshesPublishedState() async {
    let hardware = FakeAudioHardware(state: speakersState)
    let service = await AudioDeviceService(hardware: hardware)
    hardware.state = headphonesState
    hardware.emitChange()
    await fulfillment(of: [hardware.refreshExpectation], timeout: 1)
    XCTAssertEqual(await service.state.defaultOutputID, headphonesState.defaultOutputID)
}
```

Verify fake `stopObserving()` is called when the service deinitializes.

- [ ] **Step 5: Run service tests and the existing suite**

Run: `swift test --filter AudioDeviceServiceTests && swift test`

Expected: focused and full suites pass.

### Task 3: Add the System/Audio popover shell and ordinary Audio controls

**Files:**

- Modify: `Sources/MacStats/Views/StatsView.swift`
- Create: `Sources/MacStats/Views/AudioTab.swift`
- Modify: `Sources/MacStats/AppDelegate.swift`
- Modify: `Tests/MacStatsTests/AudioDeviceServiceTests.swift`

**Consumes:** `AudioDeviceService` from Task 2.

**Produces:** System/Audio tab navigation, injected service lifetime, and a
fully functional macOS 13-compatible device section.

- [ ] **Step 1: Write a failing pure view-model test for Audio tab presentation**

```swift
func testAudioPresentationDisablesVolumeWhenOutputDoesNotSupportIt() {
    let presentation = AudioPresentation(state: hdmiState, errorMessage: nil)
    XCTAssertFalse(presentation.isVolumeEnabled)
    XCTAssertEqual(presentation.outputControlMessage,
                   "HDMI does not expose a master volume control.")
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter AudioDeviceServiceTests/testAudioPresentation`

Expected: compilation failure naming missing `AudioPresentation`.

- [ ] **Step 3: Add `AudioPresentation` and implement `AudioTab`**

`AudioPresentation` is a pure adapter that turns `AudioDeviceState` into
picker choices and disabled-state explanations. `AudioTab` uses it to render:

```swift
Picker("Output", selection: outputBinding) { /* output devices */ }
Slider(value: volumeBinding, in: 0...1)
Toggle("Mute", isOn: muteBinding)
Picker("Input", selection: inputBinding) { /* input devices */ }
```

Bind picker, slider, and toggle writes to `AudioDeviceService`; disable a
control when no default device or no writable property exists. Include a
Refresh button and an accessible text status for errors. The input section only
selects a device and must contain no metering, monitoring, or recording code.

- [ ] **Step 4: Convert `StatsView` into the tab host without changing System content**

```swift
enum PopoverTab: String, CaseIterable, Identifiable { case system, audio }

Picker("MacStats section", selection: $selectedTab) {
    Text("System").tag(PopoverTab.system)
    Text("Audio").tag(PopoverTab.audio)
}
.pickerStyle(.segmented)
```

Move the existing body below its header into a private `systemContent` view and
render it unchanged for `.system`; render `AudioTab` for `.audio`. Preserve the
existing 320-point System width but allow AudioTab to request a 360-point width.

- [ ] **Step 5: Give `AppDelegate` one service instance and inject it**

```swift
private let audioDevices = AudioDeviceService()
private let appMixer = AppMixerService()
```

Pass both as environment objects while building the popover. Do not construct
services from a SwiftUI `body`.

- [ ] **Step 6: Run automated checks and manually verify macOS 13 controls**

Run: `swift test && swift build`

Manual expected result: System remains the first tab; Audio lists devices;
output/input selection, available master volume, and mute reflect System
Settings changes; unsupported controls explain why they are disabled.

### Task 4: Add availability, permission, and process-domain app-mixer models

**Files:**

- Create: `Sources/MacStats/Audio/AppMixerService.swift`
- Modify: `Tests/MacStatsTests/AppMixerServiceTests.swift`

**Consumes:** audio models from Task 1.

**Produces:** `AppMixerCapability`, `AudioCapturePermission`, `AudioProcess`,
`AppMixerService`, and a fakeable `AppMixerBackend` protocol.

- [ ] **Step 1: Write failing capability and permission tests**

```swift
func testMacOS13NeverRequestsCapturePermission() async {
    let backend = FakeAppMixerBackend(permission: .notDetermined)
    let service = await AppMixerService(backend: backend, supportsTaps: false)
    await service.enable()
    XCTAssertEqual(await service.capability, .requiresMacOS142)
    XCTAssertEqual(backend.permissionRequestCount, 0)
}

func testPermissionDenialLeavesMixerStopped() async {
    let backend = FakeAppMixerBackend(permission: .denied)
    let service = await AppMixerService(backend: backend, supportsTaps: true)
    await service.enable()
    XCTAssertFalse(await service.isRunning)
    XCTAssertEqual(await service.statusMessage, "System audio capture permission was not granted.")
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter AppMixerServiceTests`

Expected: compilation failure naming missing app-mixer types.

- [ ] **Step 3: Implement the availability-gated service and backend contract**

```swift
enum AppMixerCapability: Equatable { case requiresMacOS142, available }
enum AudioCapturePermission: Equatable { case notDetermined, granted, denied }

protocol AppMixerBackend: AnyObject {
    func capturePermission() -> AudioCapturePermission
    func requestCapturePermission() async -> AudioCapturePermission
    func activeOutputProcesses() throws -> [AudioProcess]
    func start(processes: [AudioProcess], outputDeviceID: AudioObjectID) throws -> AppMixerSession
}
```

`AppMixerService.enable()` first checks `supportsTaps`, then asks permission
only for `.notDetermined`, then reads active output processes, and starts one
session only when there is an available output device. It reports a specific
message for no audible processes and does not retry automatically.

- [ ] **Step 4: Implement process discovery in the real backend behind `#available(macOS 14.2, *)`**

Read `kAudioHardwarePropertyProcessObjectList`; retain only processes whose
`kAudioProcessPropertyIsRunningOutput` is true. Read
`kAudioProcessPropertyPID` and `kAudioProcessPropertyBundleID`; resolve names
and icons through `NSRunningApplication` where possible, then fall back to the
executable name. Do not create taps in this task.

- [ ] **Step 5: Run focused tests and the full suite**

Run: `swift test --filter AppMixerServiceTests && swift test`

Expected: all tests pass; the test process never asks the operating system for
capture permission.

### Task 5: Implement the per-app session, gain state, and guaranteed teardown

**Files:**

- Create: `Sources/MacStats/Audio/AppMixerSession.swift`
- Modify: `Sources/MacStats/Audio/AppMixerService.swift`
- Modify: `Tests/MacStatsTests/AppMixerServiceTests.swift`
- Modify: `Sources/MacStats/AppDelegate.swift`

**Consumes:** `AudioProcess`, `AppMixerBackend`, and the default output from
`AudioDeviceService`.

**Produces:** an idempotent `AppMixerSession.stop()`, process gain/mute
controls, and lifecycle teardown calls from the application delegate.

- [ ] **Step 1: Write failing cleanup and gain tests**

```swift
func testDisableStopsEveryCreatedTapAndAggregateExactlyOnce() async {
    let backend = FakeAppMixerBackend(permission: .granted, processes: [music, video])
    let service = await AppMixerService(backend: backend, supportsTaps: true)
    await service.enable()
    await service.disable()
    await service.disable()
    XCTAssertEqual(backend.destroyedTapIDs.count, 2)
    XCTAssertEqual(backend.destroyedAggregateIDs.count, 1)
}

func testMutingAProcessSetsItsRenderGainToZero() async {
    let session = AppMixerSession.testing(processes: [music])
    session.setMuted(true, for: music.id)
    XCTAssertEqual(session.renderGain(for: music.id), 0)
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter AppMixerServiceTests/testDisable`

Expected: failure because session lifecycle and render gain are absent.

- [ ] **Step 3: Implement real-time-safe gain storage and `AppMixerSession.stop()`**

Store one `Float` gain and one mute bit per process in a lock-free atomic or a
preallocated lock-protected buffer that is never resized by the render callback.
`setGain(_:for:)` clamps to `0...1`; `setMuted(_:for:)` changes the effective
gain to zero while retaining the slider’s saved gain. `stop()` must be safe to
call repeatedly and execute, in order: stop I/O, destroy aggregate device,
destroy all process taps, clear IDs and gain state.

- [ ] **Step 4: Implement the macOS 14.2+ Core Audio session factory**

For every selected process, create a `CATapDescription`, create the process tap,
then create one private aggregate device containing those taps and configured
for the selected output. Start I/O only after every resource succeeds. If any
creation fails, call the same `stop()` path to destroy resources already made
and surface the original error. The render callback multiplies each stream by
the current effective gain and writes only to the aggregate output buffer.

- [ ] **Step 5: Wire all mandatory stop paths**

In `AppMixerService`, call `disable()` when the Audio tab disappears, when
`AudioDeviceService` publishes a changed default output ID, and when permission
becomes denied. In `AppDelegate.tearDown()`, call `appMixer.disable()` before
stopping `StatsEngine`.

- [ ] **Step 6: Run session tests, full tests, and build**

Run: `swift test --filter AppMixerServiceTests && swift test && swift build`

Expected: all pass with no live capture started by automated tests.

### Task 6: Surface app-mixer controls and document verified behavior

**Files:**

- Modify: `Sources/MacStats/Views/AudioTab.swift`
- Modify: `README.md`
- Modify: `docs/guide.html`
- Modify: `Tests/MacStatsTests/AppMixerServiceTests.swift`

**Consumes:** `AppMixerService` from Tasks 4–5.

**Produces:** an accessible feature gate and process rows with controls that
match actual runtime capability.

- [ ] **Step 1: Add failing presentation tests for required/denied/active states**

```swift
func testRequiresMacOS142PresentationHasNoEnableAction() {
    let presentation = AppMixerPresentation(capability: .requiresMacOS142,
                                             permission: .notDetermined,
                                             isRunning: false, processes: [])
    XCTAssertFalse(presentation.showsEnableButton)
    XCTAssertEqual(presentation.message,
                   "Application mixing requires macOS 14.2 or later.")
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter AppMixerServiceTests/testRequiresMacOS142Presentation`

Expected: compilation failure naming missing `AppMixerPresentation`.

- [ ] **Step 3: Implement the App Mixer section of `AudioTab`**

Render a privacy explanation before enable: audio stays on the Mac and is not
recorded. Show Enable only for `.available` and a stopped session. For a running
session, render each `AudioProcess` with icon, accessible name, slider, mute
toggle, and unavailable status. Expose a Disable control. Call `disable()` from
`.onDisappear` for the Audio tab.

- [ ] **Step 4: Update documentation only after manual verification passes**

Add an Audio section that states: device controls require macOS 13+;
application mixing requires macOS 14.2+, an explicit permission decision, and
only controls app processes; browser tabs, recording, and virtual devices are
not included. State that the mixer ends when disabled, output changes, the tab
closes, or MacStats quits.

- [ ] **Step 5: Run final automated checks**

Run: `swift test && swift build && bash -n Scripts/*.sh && git diff --check`

Expected: all commands succeed with no whitespace errors.

- [ ] **Step 6: Perform hardware verification before calling the feature complete**

On macOS 13: verify normal device controls and the no-permission app-mixer
explanation. On macOS 14.2+: verify permission denial, two simultaneously
audible apps with independent gain/mute, and cleanup after tab close, output
change, permission revocation, and quit. Record the tested macOS versions and
devices in the eventual pull request or release notes.

## Plan self-review

- **Spec coverage:** Tasks 1–3 cover macOS 13 device inspection/selection,
  master volume/mute, UI, and error states. Tasks 4–6 cover macOS 14.2
  capability gating, permission, process discovery, taps/aggregate session,
  real-time gain, teardown, privacy copy, and manual verification. Browser tabs,
  virtual devices, recording, and background capture remain excluded.
- **Placeholders:** scanned for deferred work markers and generic test steps;
  each task has concrete types, tests, commands, and expected outcomes.
- **Type consistency:** `AudioDeviceService` owns normal device state;
  `AppMixerService` owns process-session state; both use `AudioObjectID` and
  expose only UI-safe models to SwiftUI.
