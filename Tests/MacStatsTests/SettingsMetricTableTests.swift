import XCTest
@testable import MacStats

/// The Settings metrics table addresses both the popover card flags and the
/// menu bar selection by `MenuBarMetric`; these pin that mapping to the
/// persisted keys so existing preferences survive the redesign.
final class SettingsMetricTableTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsMetricTableTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let cardKeys: [MenuBarMetric: String] = [
        .cpu: AppSettings.Key.showCPU,
        .gpu: AppSettings.Key.showGPU,
        .ram: AppSettings.Key.showMemory,
        .disk: AppSettings.Key.showDisk,
        .network: AppSettings.Key.showNetwork,
        .battery: AppSettings.Key.showBattery,
        .fan: AppSettings.Key.showFan,
        .temp: AppSettings.Key.showTemperature
    ]

    // MARK: - Card column

    func testEachCardCheckboxWritesOnlyItsOwnPersistedKey() {
        for metric in MenuBarMetric.allCases {
            let settings = AppSettings(defaults: defaults)
            settings.setShown(metric, in: .card, false)

            for (other, key) in cardKeys {
                XCTAssertEqual(defaults.bool(forKey: key), other != metric,
                               "hiding \(metric) card changed \(key)")
            }
            settings.setShown(metric, in: .card, true)
        }
    }

    func testCardColumnReadsExistingPreferences() {
        defaults.set(false, forKey: AppSettings.Key.showGPU)
        defaults.set(false, forKey: AppSettings.Key.showTemperature)
        let settings = AppSettings(defaults: defaults)

        let shown = MenuBarMetric.allCases.filter { settings.isShown($0, in: .card) }
        XCTAssertEqual(shown, [.cpu, .ram, .disk, .network, .battery, .fan])
    }

    func testHidingEveryCardClearsHasVisibleCards() {
        let settings = AppSettings(defaults: defaults)
        MenuBarMetric.allCases.forEach { settings.setShown($0, in: .card, false) }
        XCTAssertFalse(settings.hasVisibleCards)
        settings.setShown(.fan, in: .card, true)
        XCTAssertTrue(settings.hasVisibleCards)
    }

    // MARK: - Menu bar column

    func testMenuBarColumnReadsExistingSelection() {
        defaults.set(["temp", "ram"], forKey: AppSettings.Key.menuBarItems)
        let settings = AppSettings(defaults: defaults)

        let shown = MenuBarMetric.allCases.filter { settings.isShown($0, in: .menuBar) }
        XCTAssertEqual(shown, [.ram, .temp])
    }

    func testMenuBarColumnKeepsStoredIdentifiersAndCanonicalOrder() {
        let settings = AppSettings(defaults: defaults)
        settings.setShown(.temp, in: .menuBar, true)
        settings.setShown(.ram, in: .menuBar, true)

        XCTAssertEqual(defaults.stringArray(forKey: AppSettings.Key.menuBarItems), ["cpu", "temp", "ram"])
        XCTAssertEqual(settings.menuBarMetrics, [.cpu, .ram, .temp])
    }

    func testColumnsAreIndependent() {
        let settings = AppSettings(defaults: defaults)
        settings.setShown(.cpu, in: .menuBar, false)
        XCTAssertTrue(settings.isShown(.cpu, in: .card))

        settings.setShown(.gpu, in: .card, false)
        settings.setShown(.gpu, in: .menuBar, true)
        XCTAssertFalse(settings.showGPU)
        XCTAssertEqual(settings.menuBarMetrics, [.gpu])
    }

    // MARK: - Labels

    func testSettingsTitlesAreUniqueAndSpelledOut() {
        let titles = MenuBarMetric.allCases.map(\.settingsTitle)
        XCTAssertEqual(Set(titles).count, titles.count)
        for title in titles {
            XCTAssertFalse(title.hasPrefix("Show "), "\(title) repeats the toggle verb")
            XCTAssertGreaterThan(title.count, 3, "\(title) reads like a menu bar abbreviation")
        }
    }

    func testEveryCheckboxHasADistinctAccessibilityLabelNamingMetricAndColumn() {
        var labels: Set<String> = []
        for metric in MenuBarMetric.allCases {
            for placement in MetricPlacement.allCases {
                let label = placement.accessibilityLabel(for: metric)
                XCTAssertTrue(label.contains(metric.settingsTitle), label)
                XCTAssertTrue(label.contains(placement.columnTitle), label)
                labels.insert(label)
            }
        }
        XCTAssertEqual(labels.count, MenuBarMetric.allCases.count * MetricPlacement.allCases.count)
    }

    func testColumnTitles() {
        XCTAssertEqual(MetricPlacement.allCases.map(\.columnTitle), ["Card", "Menu bar"])
    }

    // MARK: - Launch at Login copy

    func testLaunchAtLoginErrorsAvoidJargon() {
        let messages = [
            LaunchAtLogin.Failure.unsupported.errorDescription,
            LaunchAtLogin.Failure.system("The operation couldn’t be completed.").errorDescription
        ].compactMap { $0 }
        XCTAssertEqual(messages.count, 2)
        for message in messages {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("launchd"), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("bundle"), message)
        }
    }
}
