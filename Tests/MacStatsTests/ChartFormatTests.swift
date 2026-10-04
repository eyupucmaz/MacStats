import Foundation
import XCTest
@testable import MacStats

/// Axis, tooltip and spoken values per unit, the stats row and the range
/// picker labels, in English and Turkish.
final class ChartFormatTests: XCTestCase {
    private let english = Locale(identifier: "en_US_POSIX")
    private let turkish = Locale(identifier: "tr_TR")

    // MARK: - Axis labels (snapshot per unit)

    private let axisCases: [(value: Double, unit: MetricUnit, step: Double)] = [
        (50, .percent, 25),
        (500_000, .bytesPerSecond, 500_000),
        (1_500_000, .bytesPerSecond, 500_000),
        (2_000_000_000, .bytes, 2e9),
        (2_500, .rpm, 500),
        (55, .celsius, 5),
        (0.5, .watts, 0.5),
        (3, .count, 1),
    ]

    func testAxisLabelsInEnglish() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(axisCases.map { MetricValueFormat.axis($0.value, unit: $0.unit, step: $0.step, locale: english) },
                           ["50%", "500 KB/s", "1.5 MB/s", "2.0 GB", "2500 RPM", "55°C", "0.5 W", "3"])
        }
    }

    func testAxisLabelsInTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(axisCases.map { MetricValueFormat.axis($0.value, unit: $0.unit, step: $0.step, locale: turkish) },
                           ["%50", "500 KB/sn", "1,5 MB/sn", "2,0 GB", "2500 dev/dk", "55°C", "0,5 W", "3"])
        }
    }

    func testEveryTickOfAScaleGetsADistinctLabel() {
        L10n.$language.withValue("en") {
            for (unit, maximum) in [(MetricUnit.percent, 80.0), (.bytesPerSecond, 1_200_000), (.bytes, 7e9),
                                    (.watts, 0.3), (.watts, 14), (.count, 3)] {
                let scale = ChartValueScale.make(unit: unit, minimum: 0, maximum: maximum)
                let labels = scale.ticks.map { MetricValueFormat.axis($0, unit: unit, step: scale.step, locale: english) }
                XCTAssertEqual(Set(labels).count, labels.count, "\(unit): \(labels)")
            }
        }
    }

    // MARK: - Tooltip and spoken values

    func testShortValues() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(MetricValueFormat.short(23.4, unit: .percent, locale: english), "23.4%")
            XCTAssertEqual(MetricValueFormat.short(1_200_000, unit: .bytesPerSecond, locale: english), "1.2 MB/s")
            XCTAssertEqual(MetricValueFormat.short(820_000_000, unit: .bytes, locale: english), "820 MB")
            XCTAssertEqual(MetricValueFormat.short(2_502, unit: .rpm, locale: english), "2502 RPM")
            XCTAssertEqual(MetricValueFormat.short(53.44, unit: .celsius, locale: english), "53.4°C")
            XCTAssertEqual(MetricValueFormat.short(4.5, unit: .watts, locale: english), "4.5 W")
            XCTAssertEqual(MetricValueFormat.short(12.3, unit: .watts, locale: english), "12 W")
            XCTAssertEqual(MetricValueFormat.short(7, unit: .count, locale: english), "7")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(MetricValueFormat.short(23.4, unit: .percent, locale: turkish), "%23,4")
            XCTAssertEqual(MetricValueFormat.short(1_200_000, unit: .bytesPerSecond, locale: turkish), "1,2 MB/sn")
            XCTAssertEqual(MetricValueFormat.short(2_502, unit: .rpm, locale: turkish), "2502 dev/dk")
            XCTAssertEqual(MetricValueFormat.short(53.44, unit: .celsius, locale: turkish), "53,4°C")
        }
    }

    func testSpokenValues() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(MetricValueFormat.spoken(23.4, unit: .percent, locale: english), "23.4 percent")
            XCTAssertEqual(MetricValueFormat.spoken(1_200_000, unit: .bytesPerSecond, locale: english),
                           "1.2 megabytes per second")
            XCTAssertEqual(MetricValueFormat.spoken(2_502, unit: .rpm, locale: english), "2502 revolutions per minute")
            XCTAssertEqual(MetricValueFormat.spoken(53.4, unit: .celsius, locale: english), "53.4 degrees Celsius")
            XCTAssertEqual(MetricValueFormat.spoken(4.5, unit: .watts, locale: english), "4.5 watts")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(MetricValueFormat.spoken(23.4, unit: .percent, locale: turkish), "yüzde 23,4")
            XCTAssertEqual(MetricValueFormat.spoken(1_200_000, unit: .bytesPerSecond, locale: turkish),
                           "saniyede 1,2 megabayt")
            XCTAssertEqual(MetricValueFormat.spoken(2_502, unit: .rpm, locale: turkish), "dakikada 2502 devir")
            XCTAssertEqual(MetricValueFormat.spoken(53.4, unit: .celsius, locale: turkish), "53,4 santigrat derece")
            XCTAssertEqual(MetricValueFormat.spoken(4.5, unit: .watts, locale: turkish), "4,5 vat")
        }
    }

    func testTimeOfASample() {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MetricValueFormat.time(date, locale: turkish, timeZone: utc), "14:13:20")
        XCTAssertEqual(MetricValueFormat.time(date, seconds: false, locale: turkish, timeZone: utc), "14:13")
        XCTAssertEqual(MetricValueFormat.time(date, locale: Locale(identifier: "en_GB"), timeZone: utc), "14:13:20")
    }

    // MARK: - Stats row

    private let statistics = SeriesStatistics(min: 4.2, average: 23.4, max: 81)

    func testStatsRowInEnglish() {
        L10n.$language.withValue("en") {
            let summary = SeriesStatsSummary(statistics: statistics, unit: .percent, locale: english)
            XCTAssertEqual(summary.items, [.init(label: "Min", value: "4.2%"),
                                           .init(label: "Avg", value: "23.4%"),
                                           .init(label: "Max", value: "81.0%")])
            XCTAssertEqual(summary.accessibilityLabel,
                           "Minimum 4.2 percent, average 23.4 percent, maximum 81.0 percent")

            let network = SeriesStatsSummary(statistics: SeriesStatistics(min: 0, average: 412_000, max: 2_300_000),
                                             unit: .bytesPerSecond, title: "Download", locale: english)
            XCTAssertEqual(network.items.map(\.value), ["0 B/s", "412 KB/s", "2.3 MB/s"])
            XCTAssertTrue(network.accessibilityLabel.hasPrefix("Download, Minimum 0 bytes per second"))
        }
    }

    func testStatsRowInTurkish() {
        L10n.$language.withValue("tr") {
            let summary = SeriesStatsSummary(statistics: statistics, unit: .percent, locale: turkish)
            XCTAssertEqual(summary.items, [.init(label: "En az", value: "%4,2"),
                                           .init(label: "Ort.", value: "%23,4"),
                                           .init(label: "En çok", value: "%81,0")])
            XCTAssertEqual(summary.accessibilityLabel, "En düşük yüzde 4,2, ortalama yüzde 23,4, en yüksek yüzde 81,0")

            let celsius = SeriesStatsSummary(statistics: SeriesStatistics(min: 41.25, average: 55.7, max: 78.4),
                                             unit: .celsius, locale: turkish)
            XCTAssertEqual(celsius.items.map(\.value), ["41,3°C", "55,7°C", "78,4°C"])
        }
    }

    func testStatsRowWithoutDataShowsNoInventedValues() {
        L10n.$language.withValue("en") {
            let summary = SeriesStatsSummary(statistics: nil, unit: .rpm, locale: english)
            XCTAssertEqual(summary.items.map(\.value), ["—", "—", "—"])
            XCTAssertEqual(summary.accessibilityLabel, "No statistics yet")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(SeriesStatsSummary(statistics: nil, unit: .rpm, locale: turkish).accessibilityLabel,
                           "Henüz istatistik yok")
        }
    }

    // MARK: - Range picker

    func testRangeLabels() {
        XCTAssertEqual(HistoryRange.default, .fiveMinutes)
        L10n.$language.withValue("en") {
            XCTAssertEqual(HistoryRange.allCases.map(\.chartShortLabel), ["1 m", "5 m", "15 m", "1 h"])
            XCTAssertEqual(HistoryRange.allCases.map(\.chartSpokenLabel), ["1 minute", "5 minutes", "15 minutes", "1 hour"])
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(HistoryRange.allCases.map(\.chartShortLabel), ["1 dk", "5 dk", "15 dk", "1 sa"])
            XCTAssertEqual(HistoryRange.allCases.map(\.chartSpokenLabel), ["1 dakika", "5 dakika", "15 dakika", "1 saat"])
        }
    }

    func testMemoryUsesBinaryUnitsLikeTheRAMCard() {
        // 8.2 GiB reads "8.2 GB" here and on the card, not the decimal "8.8 GB".
        XCTAssertEqual(MetricValueFormat.short(8_804_682_138, unit: .memory, locale: english), "8.2 GB")
        // One decimal up to 100 GB, like the card's "12.4/16 GB" (was "12 GB" next to it).
        XCTAssertEqual(MetricValueFormat.short(13_314_398_618, unit: .memory, locale: english), "12.4 GB")
        XCTAssertEqual(MetricValueFormat.short(8_804_682_138, unit: .bytes, locale: english), "8.8 GB")
        XCTAssertEqual(MetricValueFormat.short(512 * 1_048_576, unit: .memory, locale: english), "512 MB")
    }

    func testMemoryAxisTicksLandOnWholeBinarySizes() {
        let scale = ChartValueScale.make(unit: .memory, minimum: 0, maximum: 12 * 1_073_741_824)
        let labels = scale.ticks.map { MetricValueFormat.axis($0, unit: .memory, step: scale.step, locale: english) }
        XCTAssertEqual(labels, ["0 B", "5.0 GB", "10 GB", "15 GB"])
    }
}
