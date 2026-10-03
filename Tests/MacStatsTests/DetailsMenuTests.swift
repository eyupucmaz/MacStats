import XCTest
@testable import MacStats

/// The status menu's Details submenu and the route the popover opens on (#33).
@MainActor
final class DetailsMenuTests: XCTestCase {

    // MARK: - Initial route

    private func route(
        _ trigger: PopoverOpenTrigger,
        _ menuBar: [MenuBarMetric],
        setting: Bool
    ) -> SystemRoute {
        DetailNavigation.initialRoute(for: trigger, menuBarMetrics: menuBar, opensSingleMetricDetails: setting)
    }

    func testTheDetailsMenuOpensTheChosenPageWhateverTheSettings() {
        for metric in MenuBarMetric.allCases {
            for setting in [false, true] {
                for menuBar in [[], [.cpu], [.cpu, .ram], MenuBarMetric.allCases] as [[MenuBarMetric]] {
                    XCTAssertEqual(route(.detailsMenu(metric), menuBar, setting: setting), .detail(metric))
                }
            }
        }
    }

    func testAClickOpensTheGridWhileTheSettingIsOff() {
        XCTAssertEqual(route(.statusItem, [], setting: false), .grid)
        XCTAssertEqual(route(.statusItem, [.gpu], setting: false), .grid)
        XCTAssertEqual(route(.statusItem, [.cpu, .temp], setting: false), .grid)
    }

    func testAClickOnASingleMetricOpensItsPageWhenTheSettingIsOn() {
        for metric in MenuBarMetric.allCases {
            XCTAssertEqual(route(.statusItem, [metric], setting: true), .detail(metric))
        }
    }

    /// No metric means the app glyph; several make the click ambiguous.
    func testTheSettingHasNoEffectWithNoneOrSeveralMetrics() {
        XCTAssertEqual(route(.statusItem, [], setting: true), .grid)
        XCTAssertEqual(route(.statusItem, [.cpu, .ram], setting: true), .grid)
        XCTAssertEqual(route(.statusItem, MenuBarMetric.allCases, setting: true), .grid)
    }

    /// The first-launch open shows the welcome hint above the grid.
    func testTheOnboardingOpenAlwaysShowsTheGrid() {
        XCTAssertEqual(route(.onboarding, [.cpu], setting: true), .grid)
        XCTAssertEqual(route(.onboarding, [], setting: false), .grid)
    }

    /// Reads the menu bar selection the way `AppDelegate` does, in canonical order.
    func testRoutingFollowsTheStoredMenuBarSelection() {
        let suite = "MacStatsTests.DetailsMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.opensSingleMetricDetails = true
        settings.menuBarItems = [MenuBarMetric.battery.rawValue, "unknown"]
        XCTAssertEqual(
            route(.statusItem, settings.menuBarMetrics, setting: settings.opensSingleMetricDetails),
            .detail(.battery),
            "an unknown stored identifier must not count as a second metric"
        )
    }

    // MARK: - Navigation

    /// A page opened from the menu lands on the System tab, even if the popover was left on Audio.
    func testShowSwitchesToTheSystemTab() {
        let navigation = DetailNavigation()
        navigation.tab = .audio
        navigation.show(.fan)
        XCTAssertEqual(navigation.tab, .system)
        XCTAssertEqual(navigation.route, .detail(.fan))
    }

    /// Closing the popover returns to the grid but keeps the tab, as before.
    func testBackKeepsTheTab() {
        let navigation = DetailNavigation()
        navigation.show(.disk)
        navigation.tab = .audio
        navigation.back()
        XCTAssertEqual(navigation.route, .grid)
        XCTAssertEqual(navigation.tab, .audio)
    }

    // MARK: - Menu items

    func testTheMenuListsEveryMetricInCardOrder() {
        XCTAssertEqual(DetailsMenu.items.map(\.metric), MenuBarMetric.allCases)
        XCTAssertEqual(DetailsMenu.items.count, 8)
    }

    func testItemsUseThePageTitles() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(DetailsMenu.title, "Details")
            XCTAssertEqual(DetailsMenu.items.map(\.title),
                           ["CPU", "GPU", "Memory", "Disk", "Network", "Battery", "Fan", "Temperature"])
        }
    }

    func testItemsUseTheCardSymbols() {
        let s = StatsSnapshot(
            cpuUsage: 10, gpuUsage: 10, isGPUAvailable: true,
            memoryUsed: 1, memoryTotal: 2,
            diskUsedBytes: 1, diskTotalBytes: 2,
            networkDownBytes: 0, networkUpBytes: 0,
            batteryLevel: 100, batteryState: "Full",
            fanRPM: 1000, isFanAvailable: true,
            temperature: 40, isTemperatureAvailable: true
        )
        for item in DetailsMenu.items {
            XCTAssertEqual(item.symbol, item.metric.card(s).icon, "\(item.metric)")
        }
    }

    func testMenuAndSettingRenderInTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(DetailsMenu.title, "Ayrıntılar")
            XCTAssertEqual(DetailsMenu.items.map(\.title)[2], "Bellek")
            XCTAssertEqual(L10n.string("Opens the \("Bellek") page in MacStats."), "MacStats'te Bellek sayfasını açar.")
            XCTAssertEqual(L10n.string("Open details when clicking a single menu bar metric"),
                           "Menü çubuğundaki tek ölçüme tıklayınca ayrıntılarını aç")
        }
    }
}
