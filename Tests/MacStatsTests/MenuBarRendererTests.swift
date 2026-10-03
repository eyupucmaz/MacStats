import AppKit
import XCTest
@testable import MacStats

/// The menu bar title is the one piece of UI visible without opening anything,
/// so its formatting is pinned down here rather than eyeballed.
final class MenuBarRendererTests: XCTestCase {
    /// Pinned so the expectations hold whatever the machine's region is.
    private let posix = Locale(identifier: "en_US_POSIX")

    /// A fully-populated snapshot; individual tests override the fields they care about.
    private func snapshot() -> StatsSnapshot {
        StatsSnapshot(
            cpuUsage: 23.4,
            gpuUsage: 15.2,
            isGPUAvailable: true,
            memoryUsed: 8_804_682_138,   // ~8.2 GiB
            memoryTotal: 17_179_869_184, // 16 GiB
            diskUsedBytes: 300_000_000_000,  // 300 GB
            diskTotalBytes: 494_000_000_000, // 494 GB
            networkDownBytes: 1_200_000, // 1.2 MB/s
            networkUpBytes: 340_000,     // 340 KB/s
            batteryLevel: 87,
            batteryState: "Discharging",
            fanRPM: 2502,
            isFanAvailable: true,
            temperature: 53.4,
            isTemperatureAvailable: true
        )
    }

    // MARK: - Per-metric formatting

    func testCPUSegmentRoundsToWholePercent() {
        XCTAssertEqual(MenuBarRenderer.segment(.cpu, snapshot(), locale: posix), "CPU 23%")
    }

    func testGPUSegmentRoundsToWholePercent() {
        XCTAssertEqual(MenuBarRenderer.segment(.gpu, snapshot(), locale: posix), "GPU 15%")
    }

    func testMemorySegmentShowsUsedGigabytes() {
        XCTAssertEqual(MenuBarRenderer.segment(.ram, snapshot(), locale: posix), "RAM 8.2G")
    }

    func testDiskSegmentShowsUsedPercent() {
        XCTAssertEqual(MenuBarRenderer.segment(.disk, snapshot(), locale: posix), "DSK 61%")
    }

    func testDiskSegmentIsUnavailableWithoutTotal() {
        var s = snapshot()
        s.diskTotalBytes = 0
        XCTAssertEqual(MenuBarRenderer.segment(.disk, s, locale: posix), "DSK —")
    }

    func testDiskSizeUsesDecimalUnits() {
        XCTAssertEqual(DiskSize.short(820_000_000, locale: posix), "820 MB")
        XCTAssertEqual(DiskSize.short(9_700_000_000, locale: posix), "9.7 GB")
        XCTAssertEqual(DiskSize.short(245_000_000_000, locale: posix), "245 GB")
        XCTAssertEqual(DiskSize.short(1_200_000_000_000, locale: posix), "1.2 TB")
    }

    func testNetworkSegmentShowsBothDirections() {
        XCTAssertEqual(MenuBarRenderer.segment(.network, snapshot(), locale: posix), "NET ↓1.2M ↑340K")
    }

    func testNetworkSegmentUsesDecimalUnits() {
        var s = snapshot()
        s.networkDownBytes = 1_258_291
        s.networkUpBytes = 999_960
        XCTAssertEqual(MenuBarRenderer.segment(.network, s, locale: posix), "NET ↓1.3M ↑1.0M")
    }

    func testDecimalsFollowTheLocale() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(MenuBarRenderer.segment(.ram, snapshot(), locale: german), "RAM 8,2G")
        XCTAssertEqual(MenuBarRenderer.segment(.network, snapshot(), locale: german), "NET ↓1,2M ↑340K")
    }

    func testBatterySegmentShowsPercent() {
        XCTAssertEqual(MenuBarRenderer.segment(.battery, snapshot(), locale: posix), "BAT 87%")
    }

    func testFanSegmentShowsRPMWithoutUnit() {
        XCTAssertEqual(MenuBarRenderer.segment(.fan, snapshot(), locale: posix), "FAN 2502")
    }

    func testTemperatureSegmentRoundsToWholeDegrees() {
        XCTAssertEqual(MenuBarRenderer.segment(.temp, snapshot(), locale: posix), "TMP 53°C")
    }

    // MARK: - Unavailable sensors are never faked

    func testFanSegmentReportsUnavailable() {
        var s = snapshot()
        s.isFanAvailable = false
        s.fanRPM = 0
        XCTAssertEqual(MenuBarRenderer.segment(.fan, s, locale: posix), "FAN —")
    }

    func testTemperatureSegmentReportsUnavailable() {
        var s = snapshot()
        s.isTemperatureAvailable = false
        s.temperature = 0
        XCTAssertEqual(MenuBarRenderer.segment(.temp, s, locale: posix), "TMP —")
    }

    func testGPUSegmentReportsUnavailable() {
        var s = snapshot()
        s.isGPUAvailable = false
        s.gpuUsage = 0
        XCTAssertEqual(MenuBarRenderer.segment(.gpu, s, locale: posix), "GPU —")
    }

    func testBatterySegmentReportsUnavailableOnDesktops() {
        var s = snapshot()
        s.batteryLevel = 0
        s.batteryState = "Unknown"
        XCTAssertEqual(MenuBarRenderer.segment(.battery, s, locale: posix), "BAT —")
    }

    func testMemorySegmentReportsUnavailableWithoutATotal() {
        var s = snapshot()
        s.memoryTotal = 0
        XCTAssertEqual(MenuBarRenderer.segment(.ram, s, locale: posix), "RAM —")
    }

    // MARK: - Title assembly

    func testTitleIsNilWhenNothingIsSelected() {
        XCTAssertNil(MenuBarRenderer.title([], snapshot(), locale: posix))
    }

    func testTitleJoinsSegments() {
        let title = MenuBarRenderer.title([.cpu, .ram, .temp], snapshot(), locale: posix)
        XCTAssertEqual(title, "CPU 23%  RAM 8.2G  TMP 53°C")
    }

    func testTitleKeepsTheOrderItIsGiven() {
        let title = MenuBarRenderer.title([.temp, .cpu], snapshot(), locale: posix)
        XCTAssertEqual(title, "TMP 53°C  CPU 23%")
    }

    // MARK: - Image

    func testImageIsTemplateSoTheSystemHandlesDarkModeAndHighlight() throws {
        let image = try XCTUnwrap(MenuBarRenderer.image([.cpu], snapshot()))
        XCTAssertTrue(image.isTemplate)
    }

    func testImageHasPositiveSize() throws {
        let image = try XCTUnwrap(MenuBarRenderer.image([.cpu, .ram], snapshot()))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testImageGrowsWithMoreMetrics() throws {
        let one = try XCTUnwrap(MenuBarRenderer.image([.cpu], snapshot()))
        let three = try XCTUnwrap(MenuBarRenderer.image([.cpu, .ram, .temp], snapshot()))
        XCTAssertGreaterThan(three.size.width, one.size.width)
    }

    func testImageIsNilWhenNothingIsSelected() {
        XCTAssertNil(MenuBarRenderer.image([], snapshot()))
    }

    // MARK: - Metric metadata

    func testEveryMetricHasAThreeCharacterLabel() {
        for metric in MenuBarMetric.allCases {
            XCTAssertEqual(metric.label.count, 3, "\(metric.rawValue) label is not 3 characters")
        }
    }

    func testMetricIdentifiersMatchTheStoredRawValues() {
        XCTAssertEqual(MenuBarMetric.allCases.map(\.rawValue),
                       ["cpu", "gpu", "ram", "disk", "network", "battery", "fan", "temp"])
    }
}

/// `menuBarItems` is persisted user state, so its defaults and sanitisation matter.
final class MenuBarSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsToCPUOnly() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarMetrics, [.cpu])
    }

    func testSelectionPersistsAcrossInstances() {
        let settings = AppSettings(defaults: defaults)
        settings.setMenuBarMetric(.temp, enabled: true)
        settings.setMenuBarMetric(.cpu, enabled: false)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.menuBarMetrics, [.temp])
    }

    func testUnknownIdentifiersAreIgnored() {
        defaults.set(["cpu", "not-a-metric", "temp"], forKey: AppSettings.Key.menuBarItems)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarMetrics, [.cpu, .temp])
    }

    func testMetricsAreReturnedInCanonicalOrderNotSelectionOrder() {
        defaults.set(["temp", "cpu", "ram"], forKey: AppSettings.Key.menuBarItems)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarMetrics, [.cpu, .ram, .temp])
    }

    func testEnablingIsIdempotent() {
        let settings = AppSettings(defaults: defaults)
        settings.setMenuBarMetric(.cpu, enabled: true)
        settings.setMenuBarMetric(.cpu, enabled: true)
        XCTAssertEqual(settings.menuBarItems.filter { $0 == "cpu" }.count, 1)
    }

    func testShowsMetricsInMenuBarReflectsSelection() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showsMetricsInMenuBar)
        settings.setMenuBarMetric(.cpu, enabled: false)
        XCTAssertFalse(settings.showsMetricsInMenuBar)
    }
}
