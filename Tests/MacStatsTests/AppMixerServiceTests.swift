import XCTest
@testable import MacStats

@MainActor
final class AppMixerServiceTests: XCTestCase {
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
        XCTAssertEqual(service.statusMessage, "MacStats does not have permission to capture application audio.")
        XCTAssertEqual(platform.startCount, 0)
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

    func testProcessGainAndMuteUpdatesPublishedMixerState() async {
        let process = AppMixerProcess(id: 11, processID: 123, name: "Music", gain: 1, muted: false)
        let platform = FakeAppMixerPlatform(capability: .available, permission: .authorized)
        platform.processes = [process]
        let service = AppMixerService(platform: platform)

        await service.enable()
        service.setGain(0.35, for: process.processID)
        service.setMuted(true, for: process.processID)

        XCTAssertEqual(service.processes.first?.gain, 0.35)
        XCTAssertEqual(service.processes.first?.muted, true)
    }
}

private final class FakeAppMixerPlatform: AppMixerPlatform {
    let capability: AppMixerCapability
    var permission: AppMixerPermission
    var permissionRequestCount = 0
    var startCount = 0
    var stopCount = 0
    var processes: [AppMixerProcess] = []

    init(capability: AppMixerCapability, permission: AppMixerPermission = .notDetermined) {
        self.capability = capability
        self.permission = permission
    }

    func requestPermission() async -> AppMixerPermission {
        permissionRequestCount += 1
        return permission
    }

    func start() throws { startCount += 1 }
    func stop() { stopCount += 1 }
}
