import Combine
import Foundation
import XCTest
@testable import MacStats

@MainActor
final class AppMixerServiceTests: XCTestCase {
    private let music = AppMixerProcess(id: 11, processID: 123, name: "Music", gain: 1, muted: false)
    private let safari = AppMixerProcess(id: 12, processID: 456, name: "Safari", gain: 1, muted: false)

    func testUnsupportedPlatformDoesNotRequestPermissionOrStart() async {
        let platform = FakeAppMixerPlatform(capability: .requiresMacOS142)
        let service = AppMixerService(platform: platform)

        await service.enable()

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.statusMessage, "Application mixing requires macOS 14.2 or later.")
        XCTAssertEqual(platform.permissionRequestCount, 0)
        XCTAssertEqual(platform.startCount, 0)
    }

    func testPermissionDenialKeepsNormalDeviceControlsAvailable() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .denied)
        let service = AppMixerService(platform: platform)

        await service.enable()

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.phase, .off)
        XCTAssertEqual(service.permission, .denied)
        XCTAssertEqual(service.statusMessage, "MacStats does not have permission to capture application audio.")
        XCTAssertEqual(platform.permissionRequestCount, 0)
        XCTAssertEqual(platform.startCount, 0)
    }

    func testUndeterminedPermissionIsRequestedAndDenialIsReported() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .notDetermined)
        platform.requestResult = .denied
        let service = AppMixerService(platform: platform)

        await service.enable()

        XCTAssertEqual(platform.permissionRequestCount, 1)
        XCTAssertEqual(service.permission, .denied)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(platform.startCount, 0)
    }

    func testRefreshPermissionPublishesPreflightState() {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)
        XCTAssertEqual(service.permission, .notDetermined)

        service.refreshPermission()

        XCTAssertEqual(service.permission, .authorized)
    }

    func testEnableThenDisableTearsDownTheSession() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)

        await service.enable()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(platform.startCount, 1)

        service.disable()

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testDisableWhenOffDoesNotTouchThePlatform() {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)

        service.disable()
        service.disable()

        XCTAssertEqual(platform.stopCount, 0)
    }

    func testStartFailureReportsMessageAndReleasesResources() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        platform.startError = AppMixerError.unavailable("MacStats could not create an application audio tap.")
        let service = AppMixerService(platform: platform)

        await service.enable()

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.statusMessage, "MacStats could not create an application audio tap.")
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testProcessGainAndMuteUpdatesPublishedMixerStateAndPlatform() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        platform.discovered = [music]
        let service = AppMixerService(platform: platform)

        await service.enable()
        service.setGain(1.35, for: music.processID)
        service.setMuted(true, for: music.processID)

        XCTAssertEqual(service.processes.first?.gain, 1)
        XCTAssertEqual(service.processes.first?.muted, true)
        XCTAssertEqual(platform.applied.last?.gain, 1)
        XCTAssertEqual(platform.applied.last?.muted, true)
    }

    // MARK: - Concurrency

    func testDoubleEnableStartsOnlyOneSession() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .notDetermined)
        platform.requestGate = Gate()
        platform.permissionRequested = expectation(description: "permission requested")
        let service = AppMixerService(platform: platform)

        let first = Task { await service.enable() }
        await fulfillment(of: [platform.permissionRequested!], timeout: 5)
        XCTAssertEqual(service.phase, .requestingPermission)
        await service.enable()
        XCTAssertTrue(service.isBusy)
        platform.requestGate?.open()
        await first.value

        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(platform.permissionRequestCount, 1)
        XCTAssertEqual(platform.startCount, 1)
    }

    func testDisableWhileWaitingForPermissionNeverStarts() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .notDetermined)
        platform.requestGate = Gate()
        platform.permissionRequested = expectation(description: "permission requested")
        let service = AppMixerService(platform: platform)

        let enabling = Task { await service.enable() }
        await fulfillment(of: [platform.permissionRequested!], timeout: 5)
        XCTAssertEqual(service.phase, .requestingPermission)
        service.disable()
        platform.requestGate?.open()
        await enabling.value

        XCTAssertEqual(service.phase, .off)
        XCTAssertEqual(platform.startCount, 0)
    }

    func testDisableWhileStartingDiscardsTheStartedSession() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        platform.discovered = [music]
        platform.startGate = Gate()
        platform.startCalled = expectation(description: "session start requested")
        let service = AppMixerService(platform: platform)

        let enabling = Task { await service.enable() }
        await fulfillment(of: [platform.startCalled!], timeout: 5)
        XCTAssertEqual(service.phase, .starting)
        service.disable()
        platform.startGate?.open()
        await enabling.value

        XCTAssertEqual(service.phase, .off)
        XCTAssertTrue(service.processes.isEmpty)
        XCTAssertEqual(platform.stopCount, 1)
    }

    // MARK: - Lifecycle events

    func testProcessChangeRebuildsAndKeepsPerAppSettings() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        platform.discovered = [music]
        let service = AppMixerService(platform: platform)
        await service.enable()
        service.setGain(0.3, for: music.processID)

        platform.discovered = [music, safari]
        platform.onEvent?(.processesChanged)
        await waitFor(service.$processes, "rebuilt with both apps") { $0.count == 2 }

        XCTAssertEqual(platform.startCount, 2)
        XCTAssertEqual(platform.lastRetained.map(\.gain), [0.3])
        XCTAssertEqual(service.processes.map(\.gain), [0.3, 1])
        XCTAssertTrue(service.isRunning)
    }

    func testOutputDeviceChangeStopsTheMixer() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)
        await service.enable()

        platform.onEvent?(.outputDeviceChanged)

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(platform.stopCount, 1)
        XCTAssertEqual(service.statusMessage, AppMixerService.outputChangedMessage)
    }

    func testRevokedPermissionStopsTheMixer() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)
        await service.enable()

        platform.permission = .denied
        service.refreshPermission()

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(platform.stopCount, 1)
        XCTAssertEqual(service.statusMessage, AppMixerService.revokedMessage)
    }

    func testSleepStopsTheMixerAndWakeRestartsIt() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)
        await service.enable()

        platform.onEvent?(.willSleep)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(platform.stopCount, 1)

        platform.onEvent?(.didWake)
        await waitFor(service.$phase, "restarted after wake") { $0 == .running }
        XCTAssertEqual(platform.startCount, 2)
    }

    func testWakeDoesNotStartAMixerTheUserDisabled() async {
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        let service = AppMixerService(platform: platform)

        // Both events are handled synchronously when the mixer is off: nothing
        // is scheduled that could start it later.
        platform.onEvent?(.willSleep)
        platform.onEvent?(.didWake)

        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(platform.startCount, 0)
    }

    /// Waits for a published value matching `predicate`, without polling. The
    /// current value counts, and the service only changes on the main actor,
    /// which this test holds until it awaits here.
    private func waitFor<Value>(_ publisher: Published<Value>.Publisher, _ description: String,
                                where predicate: @escaping (Value) -> Bool) async {
        let reached = expectation(description: description)
        let subscription = publisher.first(where: predicate).sink { _ in reached.fulfill() }
        await fulfillment(of: [reached], timeout: 5)
        subscription.cancel()
    }
}

/// A one-shot latch the fake platform can park an async call on.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

private final class FakeAppMixerPlatform: AppMixerPlatform, @unchecked Sendable {
    let capability: AppMixerCapability
    var permission: AppMixerPermission
    var onEvent: (@MainActor (AppMixerEvent) -> Void)?
    var requestResult: AppMixerPermission = .authorized
    var requestGate: Gate?
    var startGate: Gate?
    /// Fulfilled when the service calls in, before any gate is waited on.
    var permissionRequested: XCTestExpectation?
    var startCalled: XCTestExpectation?
    var startError: Error?
    var discovered: [AppMixerProcess] = []
    var permissionRequestCount = 0
    var startCount = 0
    var stopCount = 0
    var lastRetained: [AppMixerProcess] = []
    var applied: [AppMixerProcess] = []

    init(capability: AppMixerCapability, permission: AppMixerPermission = .notDetermined) {
        self.capability = capability
        self.permission = permission
    }

    func requestPermission() async -> AppMixerPermission {
        permissionRequestCount += 1
        permissionRequested?.fulfill()
        await requestGate?.wait()
        permission = requestResult
        return requestResult
    }

    func start(retaining: [AppMixerProcess]) async throws -> [AppMixerProcess] {
        startCount += 1
        lastRetained = retaining
        startCalled?.fulfill()
        await startGate?.wait()
        if let startError { throw startError }
        return discovered.map { process in retaining.first { $0.processID == process.processID } ?? process }
    }

    func stop() { stopCount += 1 }
    func apply(_ process: AppMixerProcess) { applied.append(process) }
}
