import ServiceManagement
import XCTest
@testable import MacStats

/// `AppSettings` against a throwaway `UserDefaults` suite, so nothing touches the
/// user's real preferences, and a fake login item, so Launch at Login behaves the
/// same under `swift test` as inside the app.
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

    /// Off by default (#33): a click keeps opening the grid until the user opts in.
    func testSingleMetricDetailsIsOffByDefaultAndRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.opensSingleMetricDetails)

        settings.opensSingleMetricDetails = true
        XCTAssertTrue(defaults.bool(forKey: AppSettings.Key.opensSingleMetricDetails))
        XCTAssertTrue(AppSettings(defaults: defaults).opensSingleMetricDetails)
    }

    // MARK: - Launch at login

    private func settings(_ loginItem: FakeLoginItem) -> AppSettings {
        AppSettings(defaults: defaults, loginItem: loginItem)
    }

    func testUnsupportedProcessFallsBackToTheStoredFlag() {
        let loginItem = FakeLoginItem(isSupported: false, status: .enabled)
        XCTAssertFalse(settings(loginItem).launchAtLogin)
        defaults.set(true, forKey: AppSettings.Key.launchAtLogin)
        XCTAssertTrue(settings(loginItem).launchAtLogin)
        XCTAssertFalse(settings(loginItem).isLaunchAtLoginSupported)
        XCTAssertEqual(settings(loginItem).launchAtLoginStatusDescription,
                       "Not available in a development build. Install MacStats as an app to use it.")
    }

    func testSupportedProcessTrustsLaunchdOverTheStoredFlag() {
        defaults.set(true, forKey: AppSettings.Key.launchAtLogin)
        XCTAssertFalse(settings(FakeLoginItem(status: .notRegistered)).launchAtLogin)

        defaults.set(false, forKey: AppSettings.Key.launchAtLogin)
        XCTAssertTrue(settings(FakeLoginItem(status: .enabled)).launchAtLogin)
    }

    func testEnableRegistersAndPersists() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        let settings = settings(loginItem)
        XCTAssertEqual(settings.launchAtLoginStatusDescription, "MacStats won't open automatically when you log in.")

        settings.launchAtLogin = true

        XCTAssertEqual(loginItem.registerCount, 1)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.launchAtLoginError)
        XCTAssertTrue(defaults.bool(forKey: AppSettings.Key.launchAtLogin))
        XCTAssertEqual(settings.launchAtLoginStatusDescription, "MacStats will open when you log in.")
    }

    func testDisableUnregistersAndPersists() {
        let loginItem = FakeLoginItem(status: .enabled)
        let settings = settings(loginItem)

        settings.launchAtLogin = false

        XCTAssertEqual(loginItem.unregisterCount, 1)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNil(settings.launchAtLoginError)
        XCTAssertFalse(defaults.bool(forKey: AppSettings.Key.launchAtLogin))
        XCTAssertEqual(loginItem.status, .notRegistered)
    }

    func testDisablingAnUnregisteredItemSkipsTheSystemCall() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        let settings = settings(loginItem)
        settings.launchAtLogin = true
        loginItem.status = .notRegistered   // removed in System Settings meanwhile

        settings.launchAtLogin = false

        XCTAssertEqual(loginItem.unregisterCount, 0)
        XCTAssertNil(settings.launchAtLoginError)
        XCTAssertFalse(defaults.bool(forKey: AppSettings.Key.launchAtLogin))
    }

    func testEnableThatNeedsApprovalKeepsTheToggleOnAndExplainsWhy() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        loginItem.statusAfterRegister = .requiresApproval
        let settings = settings(loginItem)

        settings.launchAtLogin = true

        XCTAssertEqual(loginItem.registerCount, 1)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.launchAtLoginError)
        XCTAssertEqual(settings.launchAtLoginStatusDescription,
                       "Allow MacStats in System Settings › General › Login Items to finish turning this on.")
    }

    func testMissingLoginItemIsExplained() {
        XCTAssertEqual(settings(FakeLoginItem(status: .notFound)).launchAtLoginStatusDescription,
                       "macOS can't find MacStats' login item. Move MacStats to the Applications folder and try again.")
    }

    func testFailedEnableRevertsTheToggleAndReportsTheError() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        loginItem.error = FakeLoginItem.failure
        let settings = settings(loginItem)
        XCTAssertNil(settings.launchAtLoginError)

        settings.launchAtLogin = true

        XCTAssertEqual(loginItem.registerCount, 1)
        XCTAssertFalse(settings.launchAtLogin, "the toggle must snap back to launchd's state")
        XCTAssertEqual(settings.launchAtLoginError, "Couldn't change Launch at Login: Operation not permitted")
        XCTAssertFalse(defaults.bool(forKey: AppSettings.Key.launchAtLogin), "the reverted value is what gets stored")
    }

    func testFailedDisableRevertsToTheRealState() {
        let loginItem = FakeLoginItem(status: .enabled)
        loginItem.error = FakeLoginItem.failure
        let settings = settings(loginItem)

        settings.launchAtLogin = false

        XCTAssertEqual(loginItem.unregisterCount, 1)
        XCTAssertTrue(settings.launchAtLogin, "still registered, so the toggle snaps back on")
        XCTAssertNotNil(settings.launchAtLoginError)
        XCTAssertTrue(defaults.bool(forKey: AppSettings.Key.launchAtLogin))
    }

    func testUnsupportedChangeRevertsToTheRealState() {
        defaults.set(true, forKey: AppSettings.Key.launchAtLogin)
        let loginItem = FakeLoginItem(isSupported: false)
        let settings = settings(loginItem)

        settings.launchAtLogin = false

        XCTAssertEqual(loginItem.unregisterCount, 0)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginError, LaunchAtLogin.Failure.unsupported.errorDescription)
        XCTAssertFalse(defaults.bool(forKey: AppSettings.Key.launchAtLogin))
    }

    func testSuccessfulChangeClearsAnEarlierError() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        loginItem.error = FakeLoginItem.failure
        let settings = settings(loginItem)
        settings.launchAtLogin = true
        XCTAssertNotNil(settings.launchAtLoginError)

        loginItem.error = nil
        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.launchAtLoginError)
    }

    func testRevertPublishesOnceWithoutReentering() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        loginItem.error = FakeLoginItem.failure
        let settings = settings(loginItem)
        var published: [Bool] = []
        let subscription = settings.$launchAtLogin.dropFirst().sink { published.append($0) }

        settings.launchAtLogin = true
        subscription.cancel()

        // The user's change, then the revert; a re-entrant didSet would have recursed or added more.
        XCTAssertEqual(published, [true, false])
        XCTAssertEqual(loginItem.registerCount, 1)
    }

    func testRefreshPicksUpALoginItemRemovedElsewhere() {
        let loginItem = FakeLoginItem(status: .enabled)
        let settings = settings(loginItem)
        XCTAssertTrue(settings.launchAtLogin)

        loginItem.status = .notRegistered
        settings.refreshLaunchAtLoginState()

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(loginItem.registerCount + loginItem.unregisterCount, 0, "a refresh only reads launchd")
    }
}

/// In-memory `LoginItemService`: `register()` moves to `statusAfterRegister`,
/// `unregister()` to `.notRegistered`, unless `error` is set.
private final class FakeLoginItem: LoginItemService {
    static let failure = NSError(domain: "FakeLoginItem", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])

    let isSupported: Bool
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var error: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(isSupported: Bool = true, status: SMAppService.Status = .notRegistered) {
        self.isSupported = isSupported
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let error { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let error { throw error }
        status = .notRegistered
    }
}
