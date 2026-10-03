import Accessibility
import Foundation
import XCTest
@testable import MacStats

/// The audio-graph descriptor and the palette's contrast and dash guarantees.
final class ChartAccessibilityTests: XCTestCase {
    private let english = Locale(identifier: "en_US_POSIX")
    private let turkish = Locale(identifier: "tr_TR")
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func model(style: MetricChartStyle = .line) -> MetricChartModel {
        func series(_ id: String, _ values: [Double?]) -> MetricSeries {
            MetricSeries(id: id, unit: .percent, points: values.enumerated().map { index, value in
                MetricPoint(date: start.addingTimeInterval(Double(index)), value: value)
            })
        }
        return MetricChartModel(series: [series("cpu.user", [10, 20, nil, 23.4]), series("cpu.system", [5, 5, 5, 5])],
                                labels: ["cpu.user": "User", "cpu.system": "System"],
                                style: style, range: .fiveMinutes)
    }

    func testDescriptorDescribesAxesAndSeriesWithoutGaps() throws {
        try L10n.$language.withValue("en") {
            let descriptor = MetricChartDescriptor(title: "CPU", model: model(), locale: english,
                                                   timeZone: TimeZone(identifier: "UTC")!).makeChartDescriptor()
            XCTAssertEqual(descriptor.title, "CPU")
            XCTAssertEqual(descriptor.summary, "Last 5 minutes. Now: User 23.4 percent, System 5.0 percent")
            XCTAssertEqual(descriptor.series.map(\.name), ["User", "System"])
            XCTAssertEqual(descriptor.series.map(\.dataPoints.count), [3, 4], "gaps are left out, not zeros")
            XCTAssertTrue(descriptor.series.allSatisfy(\.isContinuous))

            let y = try XCTUnwrap(descriptor.yAxis)
            XCTAssertEqual(y.title, "Value")
            XCTAssertEqual(y.range, 0...100)
            XCTAssertEqual(y.gridlinePositions, [0, 25, 50, 75, 100])
            XCTAssertEqual(y.valueDescriptionProvider(50), "50.0 percent")

            let x = try XCTUnwrap(descriptor.xAxis as? AXNumericDataAxisDescriptor)
            XCTAssertEqual(x.title, "Time")
            XCTAssertEqual(x.range.upperBound, start.addingTimeInterval(3).timeIntervalSince1970)
            XCTAssertEqual(x.range.upperBound - x.range.lowerBound, 300)
            XCTAssertFalse(x.valueDescriptionProvider(start.timeIntervalSince1970).isEmpty)
        }
    }

    func testDescriptorPlaysOwnValuesWhenStacked() {
        let stacked = model(style: .stackedArea)
        // The audio graph plays each series' reading, not its stacked top.
        XCTAssertEqual(MetricChartDescriptor.dataPoints(of: stacked.series[1]).map(\.y), [5, 5, 5, 5])
        XCTAssertEqual(MetricChartDescriptor.dataPoints(of: stacked.series[0]).map(\.y), [10, 20, 23.4])
        XCTAssertEqual(MetricChartDescriptor.dataPoints(of: stacked.series[0]).map(\.x).last,
                       start.addingTimeInterval(3).timeIntervalSince1970)
    }

    func testDescriptorInTurkish() throws {
        try L10n.$language.withValue("tr") {
            let descriptor = MetricChartDescriptor(title: "CPU", model: model(), locale: turkish,
                                                   timeZone: TimeZone(identifier: "UTC")!).makeChartDescriptor()
            XCTAssertEqual(descriptor.summary, "Son 5 dakika. Şu an: User yüzde 23,4, System yüzde 5,0")
            let y = try XCTUnwrap(descriptor.yAxis)
            XCTAssertEqual(y.title, "Değer")
            XCTAssertEqual(y.valueDescriptionProvider(50), "yüzde 50,0")
            let x = try XCTUnwrap(descriptor.xAxis as? AXNumericDataAxisDescriptor)
            XCTAssertEqual(x.title, "Zaman")
            // Five-minute charts speak hours and minutes (2026-09-21 14:13:20 UTC).
            XCTAssertEqual(x.valueDescriptionProvider(start.timeIntervalSince1970), "14:13")
        }
    }

    func testSummaryWithoutDataNamesOnlyTheRange() {
        L10n.$language.withValue("en") {
            let empty = MetricChartModel(series: [MetricSeries(id: "a", unit: .rpm, points: [])], range: .oneHour)
            XCTAssertEqual(MetricChartDescriptor(title: "Fan", model: empty).summary, "Last 1 hour")
        }
    }

    // MARK: - Palette

    func testSeriesColorsReachNonTextContrastInLightAndDarkMode() {
        XCTAssertEqual(ChartPalette.light.count, MetricChartModel.maximumSeries)
        XCTAssertEqual(ChartPalette.dark.count, MetricChartModel.maximumSeries)
        for color in ChartPalette.light {
            for background in ChartPalette.lightBackgrounds {
                XCTAssertGreaterThanOrEqual(color.contrast(with: background), 3, "\(color) on \(background)")
            }
        }
        for color in ChartPalette.dark {
            for background in ChartPalette.darkBackgrounds {
                XCTAssertGreaterThanOrEqual(color.contrast(with: background), 3, "\(color) on \(background)")
            }
        }
    }

    func testContrastMathMatchesWCAG() {
        let white = ChartPalette.RGB(red: 255, green: 255, blue: 255)
        let black = ChartPalette.RGB(red: 0, green: 0, blue: 0)
        XCTAssertEqual(white.contrast(with: black), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrast(with: white), 1, accuracy: 0.0001)
    }

    func testEverySeriesHasItsOwnDashPattern() {
        let dashes = (0..<MetricChartModel.maximumSeries).map(ChartPalette.dash)
        XCTAssertEqual(Set(dashes).count, MetricChartModel.maximumSeries)
        XCTAssertTrue(dashes[0].isEmpty, "the first series is solid")
    }
}
