import XCTest
@testable import MacStats

/// `AppSettings` against a throwaway `UserDefaults` suite, so nothing touches the
/// user's real preferences.
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MacStatsTests.AppSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Update interval

    func testUnsetIntervalDefaultsToOneSecond() {
        XCTAssertEqual(AppSettings(defaults: defaults).updateInterval, 1.0)
    }

    func testStoredIntervalThatIsOfferedIsKept() {
        for choice in AppSettings.intervalChoices {
            defaults.set(choice, forKey: AppSettings.Key.updateInterval)
            XCTAssertEqual(AppSettings(defaults: defaults).updateInterval, choice)
        }
    }

    func testStoredIntervalThatIsNotOfferedSnapsToOneSecond() {
        for stored in [0.0, 0.5, 3.0, 10.0, 60.0, -1.0] {
            defaults.set(stored, forKey: AppSettings.Key.updateInterval)
            XCTAssertEqual(AppSettings(defaults: defaults).updateInterval, 1.0, "stored \(stored)")
        }
        defaults.set("fast", forKey: AppSettings.Key.updateInterval)
        XCTAssertEqual(AppSettings(defaults: defaults).updateInterval, 1.0, "a non-numeric value must not leak through")
    }

    func testChangedIntervalIsPersisted() {
        let settings = AppSettings(defaults: defaults)
        settings.updateInterval = 5
        XCTAssertEqual(defaults.double(forKey: AppSettings.Key.updateInterval), 5)
        XCTAssertEqual(AppSettings(defaults: defaults).updateInterval, 5)

        // Leave the shared engine on its default interval for later tests.
        settings.updateInterval = 1
    }

    // MARK: - Persistence

    func testFreshSuiteUsesTheRegisteredDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showCPU && settings.showMemory && settings.showGPU && settings.showDisk)
        XCTAssertTrue(settings.showNetwork && settings.showBattery && settings.showFan && settings.showTemperature)
        XCTAssertEqual(settings.menuBarMetrics, [.cpu])
    }

    func testCardTogglesRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.showGPU = false
        settings.showFan = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showGPU)
        XCTAssertFalse(reloaded.showFan)
        XCTAssertTrue(reloaded.showCPU)
    }

    // MARK: - Launch at login

    /// Under `swift test` the process is not an `.app` bundle, so every
    /// `SMAppService` call fails with `.unsupported`: exactly the failure path.
    private func requireUnsupportedLaunchAtLogin() throws {
        try XCTSkipIf(LaunchAtLogin.isSupported, "running from an .app bundle; the failure path cannot be forced")
    }

    func testUnsupportedProcessFallsBackToTheStoredFlag() throws {
        try requireUnsupportedLaunchAtLogin()
        XCTAssertFalse(AppSettings(defaults: defaults).launchAtLogin)
        defaults.set(true, forKey: AppSettings.Key.launchAtLogin)
        XCTAssertTrue(AppSettings(defaults: defaults).launchAtLogin)
    }

    func testFailedEnableRevertsTheToggleAndReportsTheError() throws {
        try requireUnsupportedLaunchAtLogin()
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.launchAtLoginError)

        settings.launchAtLogin = true

        XCTAssertFalse(settings.launchAtLogin, "the toggle must snap back to launchd's state")
        XCTAssertEqual(settings.launchAtLoginError, LaunchAtLogin.Failure.unsupported.errorDescription)
        XCTAssertFalse(defaults.bool(forKey: AppSettings.Key.launchAtLogin), "the reverted value is what gets stored")
    }

    func testFailedDisableStoresTheRealState() throws {
        try requireUnsupportedLaunchAtLogin()
        defaults.set(true, forKey: AppSettings.Key.launchAtLogin)
        let settings = AppSettings(defaults: defaults)

        settings.launchAtLogin = false

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNotNil(settings.launchAtLoginError)
        XCTAssertFalse(defaults.bool(forKey: AppSettings.Key.launchAtLogin))
    }

    func testRevertPublishesOnceWithoutReentering() throws {
        try requireUnsupportedLaunchAtLogin()
        let settings = AppSettings(defaults: defaults)
        var published: [Bool] = []
        let subscription = settings.$launchAtLogin.dropFirst().sink { published.append($0) }

        settings.launchAtLogin = true
        subscription.cancel()

        // The user's change, then the revert; a re-entrant didSet would have recursed or added more.
        XCTAssertEqual(published, [true, false])
    }
}
