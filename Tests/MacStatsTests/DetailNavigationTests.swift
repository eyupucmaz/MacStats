import Combine
import XCTest
@testable import MacStats

@MainActor
final class DetailNavigationTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    func testStartsAtTheGrid() {
        XCTAssertEqual(DetailNavigation().route, .grid)
    }

    func testOpensEveryMetricAndGoesBack() {
        let navigation = DetailNavigation()
        for metric in MenuBarMetric.allCases {
            navigation.open(metric)
            XCTAssertEqual(navigation.route, .detail(metric))
            navigation.back()
            XCTAssertEqual(navigation.route, .grid)
        }
    }

    /// `back()` also runs on every popover close; at the grid it must not
    /// re-render the hidden popover.
    func testBackAtTheGridPublishesNothing() {
        let navigation = DetailNavigation()
        var changes = 0
        let subscription = navigation.objectWillChange.sink { changes += 1 }
        navigation.back()
        XCTAssertEqual(changes, 0)
        navigation.open(.cpu)
        navigation.back()
        XCTAssertEqual(changes, 2)
        subscription.cancel()
    }

    func testEveryCardOpensItsOwnMetric() {
        let s = snapshot()
        for metric in MenuBarMetric.allCases {
            let card = metric.card(s, locale: posix)
            XCTAssertEqual(card.metric, metric, "card \(card.id) does not map back to \(metric)")
        }
    }

    /// The page header repeats the card, so both must come from the same factory call.
    func testHeaderValueMatchesTheCard() {
        let s = snapshot()
        XCTAssertEqual(MenuBarMetric.cpu.card(s, locale: posix), StatCardFactory.cpu(s, locale: posix))
        XCTAssertEqual(MenuBarMetric.ram.card(s, locale: posix), StatCardFactory.memory(s, locale: posix))
        XCTAssertEqual(MenuBarMetric.disk.card(s, locale: posix), StatCardFactory.disk(s, locale: posix))
        XCTAssertEqual(MenuBarMetric.battery.card(s, locale: posix), StatCardFactory.battery(s))
        XCTAssertEqual(MenuBarMetric.temp.card(s, locale: posix).value, "53.4°C")
    }

    // MARK: - Polling

    func testAVisibleDetailPageKeepsSamplingWithAStaticGlyph() {
        let navigation = DetailNavigation()
        navigation.open(.cpu)
        XCTAssertEqual(navigation.route, .detail(.cpu))
        XCTAssertTrue(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: false, popoverShown: true, selectedTab: .system))
    }

    /// The Audio tab keeps the page for when the user comes back, but nobody can see it meanwhile.
    func testAPageBehindTheAudioTabIsKeptButNotSampled() {
        let navigation = DetailNavigation()
        navigation.open(.network)
        XCTAssertFalse(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: false, popoverShown: true, selectedTab: .audio))
        XCTAssertEqual(navigation.route, .detail(.network))
    }

    // MARK: - Text

    func testPageTextRendersInTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(MenuBarMetric.ram.detailTitle, "Bellek")
            XCTAssertEqual(MenuBarMetric.temp.detailTitle, "Sıcaklık")
            XCTAssertEqual(HistoryRange.fiveMinutes.pickerLabel, "5 dk")
            XCTAssertEqual(HistoryRange.oneHour.spokenLabel, "1 saat")
            XCTAssertEqual(DetailUnavailableView.notAvailableTitle, "Bu Mac'te kullanılamıyor")
            XCTAssertEqual(DetailPlaceholderPage.title, "Ayrıntılar yakında")
        }
    }

    func testEveryRangeHasItsOwnLabel() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(HistoryRange.allCases.map(\.pickerLabel), ["1m", "5m", "15m", "1h"])
            XCTAssertEqual(Set(HistoryRange.allCases.map(\.spokenLabel)).count, HistoryRange.allCases.count)
        }
    }

    // MARK: - Helpers

    private func snapshot() -> StatsSnapshot {
        StatsSnapshot(
            cpuUsage: 23.45,
            gpuUsage: 15.2,
            isGPUAvailable: true,
            memoryUsed: 8_804_682_138,
            memoryTotal: 17_179_869_184,
            diskUsedBytes: 300_000_000_000,
            diskTotalBytes: 494_000_000_000,
            networkDownBytes: 1_200_000,
            networkUpBytes: 340_000,
            batteryLevel: 87,
            batteryState: "Discharging",
            fanRPM: 2502,
            isFanAvailable: true,
            temperature: 53.44,
            isTemperatureAvailable: true
        )
    }
}
