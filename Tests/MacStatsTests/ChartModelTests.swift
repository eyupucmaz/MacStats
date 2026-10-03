import Foundation
import XCTest
@testable import MacStats

/// Gap segmentation, stacking, the empty state and hover lookup of
/// `MetricChartModel` — the logic `MetricChart` draws from.
final class ChartModelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func series(_ id: String, _ values: [Double?], unit: MetricUnit = .percent) -> MetricSeries {
        MetricSeries(id: id, unit: unit, points: values.enumerated().map { index, value in
            MetricPoint(date: start.addingTimeInterval(Double(index)), value: value)
        })
    }

    // MARK: - Gaps

    func testSegmentsSplitAtEveryGap() {
        let runs = MetricChartModel.segments(of: series("a", [1, 2, nil, nil, 3, nil, 4, 5]).points)
        XCTAssertEqual(runs.map { $0.map(\.value) }, [[1, 2], [3], [4, 5]])
    }

    func testSegmentsOfLeadingTrailingAndAllGaps() {
        XCTAssertEqual(MetricChartModel.segments(of: series("a", [nil, 1, 2, nil]).points).map(\.count), [2])
        XCTAssertTrue(MetricChartModel.segments(of: series("a", [nil, nil]).points).isEmpty)
        XCTAssertTrue(MetricChartModel.segments(of: []).isEmpty)
    }

    func testModelDrawsOneSegmentPerRunSoNoLineCrossesAGap() {
        let model = MetricChartModel(series: [series("cpu", [10, 20, nil, 30, nil, 40, 50])], range: .oneMinute)
        XCTAssertEqual(model.segments.map(\.id), ["0-0", "0-1", "0-2"])
        XCTAssertEqual(model.segments.map { $0.points.map(\.value) }, [[10, 20], [30], [40, 50]])
        let gapDate = start.addingTimeInterval(2)
        XCTAssertFalse(model.segments.contains { $0.points.contains { $0.date == gapDate } })
    }

    // MARK: - Empty state and latest value

    func testEmptyUntilSomeSeriesHasTwoReadings() {
        XCTAssertTrue(MetricChartModel(series: []).isEmpty)
        XCTAssertTrue(MetricChartModel(series: [series("a", [5])]).isEmpty)
        XCTAssertTrue(MetricChartModel(series: [series("a", [5, nil]), series("b", [nil, 6])]).isEmpty)
        XCTAssertFalse(MetricChartModel(series: [series("a", [5, nil, 7])]).isEmpty)
    }

    func testLatestIsTheNewestReadingNotATrailingGap() {
        let model = MetricChartModel(series: [series("a", [1, 2, 3, nil])])
        XCTAssertEqual(model.series[0].latest?.value, 3)
        XCTAssertEqual(model.series[0].latest?.date, start.addingTimeInterval(2))
        XCTAssertNil(MetricChartModel(series: [series("a", [nil, nil])]).series[0].latest)
    }

    func testLabelsFallBackToTheSeriesIDAndExtraSeriesAreDropped() {
        let input = (0..<5).map { series("s\($0)", [1, 2]) }
        let model = MetricChartModel(series: input, labels: ["s0": "User"])
        XCTAssertEqual(model.series.map(\.label), ["User", "s1", "s2", "s3"])
        XCTAssertEqual(model.series.map(\.index), [0, 1, 2, 3])
    }

    func testTimeAxisEndsAtTheNewestSampleUnlessGivenAnEnd() {
        let model = MetricChartModel(series: [series("a", [1, 2, 3])], range: .oneMinute)
        XCTAssertEqual(model.timeScale.domain.upperBound, start.addingTimeInterval(2))
        XCTAssertEqual(model.timeScale.domain.lowerBound, start.addingTimeInterval(-58))

        let end = start.addingTimeInterval(30)
        let pinned = MetricChartModel(series: [series("a", [1, 2, 3])], range: .fiveMinutes, end: end)
        XCTAssertEqual(pinned.timeScale.domain, end.addingTimeInterval(-300)...end)
    }

    // MARK: - Styles

    func testStackedAreaStacksBottomUpAndBreaksOnlyTheMissingLayer() {
        let model = MetricChartModel(series: [series("user", [10, 20, nil, 30]),
                                              series("system", [5, 5, 5, nil])],
                                     style: .stackedArea)
        let user = model.segments.filter { $0.seriesIndex == 0 }
        let system = model.segments.filter { $0.seriesIndex == 1 }
        XCTAssertEqual(user.map { $0.points.map(\.high) }, [[10, 20], [30]])
        XCTAssertEqual(user.flatMap { $0.points.map(\.low) }, [0, 0, 0])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0].points.map(\.low), [10, 20, 0])
        XCTAssertEqual(system[0].points.map(\.high), [15, 25, 5])
        // The tooltip shows each layer's own reading, the dot sits on the band's top.
        XCTAssertEqual(system[0].points.map(\.value), [5, 5, 5])
        XCTAssertEqual(model.series[1].latest?.high, 5)
    }

    func testStackedScaleFitsTheSummedTop() {
        let model = MetricChartModel(series: [series("a", [600_000, 700_000], unit: .bytesPerSecond),
                                              series("b", [500_000, 600_000], unit: .bytesPerSecond)],
                                     style: .stackedArea)
        XCTAssertGreaterThanOrEqual(model.valueScale.domain.upperBound, 1_300_000)
        XCTAssertEqual(model.valueScale.domain.lowerBound, 0)
    }

    func testLineAndAreaPlotTheirOwnValues() {
        let line = MetricChartModel(series: [series("a", [10, 20]), series("b", [5, 5])], style: .line)
        XCTAssertEqual(line.segments[1].points.map(\.high), [5, 5])

        // Temperatures float above zero, so the area fills down to the axis floor.
        let area = MetricChartModel(series: [series("t", [50, 52, 51], unit: .celsius)], style: .area)
        XCTAssertGreaterThan(area.valueScale.domain.lowerBound, 0)
        XCTAssertEqual(Set(area.segments[0].points.map(\.low)), [area.valueScale.domain.lowerBound])
        XCTAssertEqual(area.segments[0].points.map(\.high), [50, 52, 51])
    }

    // MARK: - Hover

    func testNearestDatePicksTheClosestSampleWithTiesGoingEarlier() {
        let dates = (0..<5).map { start.addingTimeInterval(Double($0)) }
        XCTAssertEqual(MetricChartModel.nearest(to: start.addingTimeInterval(2.4), in: dates), dates[2])
        XCTAssertEqual(MetricChartModel.nearest(to: start.addingTimeInterval(2.6), in: dates), dates[3])
        XCTAssertEqual(MetricChartModel.nearest(to: start.addingTimeInterval(2.5), in: dates), dates[2])
        XCTAssertEqual(MetricChartModel.nearest(to: start.addingTimeInterval(-10), in: dates), dates[0])
        XCTAssertEqual(MetricChartModel.nearest(to: start.addingTimeInterval(99), in: dates), dates[4])
        XCTAssertEqual(MetricChartModel.nearest(to: start, in: [start]), start)
        XCTAssertNil(MetricChartModel.nearest(to: start, in: []))
    }

    func testHoverReportsEverySeriesAndGapsAsMissing() throws {
        let model = MetricChartModel(series: [series("user", [10, 20, nil, 30]), series("system", [5, 6, 7, 8])],
                                     labels: ["user": "User", "system": "System"])
        let hover = try XCTUnwrap(model.hover(at: start.addingTimeInterval(1.8)))
        XCTAssertEqual(hover.date, start.addingTimeInterval(2))
        XCTAssertEqual(hover.entries, [
            .init(seriesIndex: 0, label: "User", value: nil, plotted: nil),
            .init(seriesIndex: 1, label: "System", value: 7, plotted: 7),
        ])
        XCTAssertEqual(model.hover(at: start)?.entries.map(\.value), [10, 5])
        XCTAssertNil(MetricChartModel(series: []).hover(at: start))
    }

    func testStackedHoverPlotsOnTheBandTopButReportsTheOwnValue() throws {
        let model = MetricChartModel(series: [series("user", [10, 20]), series("system", [5, 6])],
                                     style: .stackedArea)
        let entry = try XCTUnwrap(model.hover(at: start.addingTimeInterval(1))?.entries.last)
        XCTAssertEqual(entry.value, 6)
        XCTAssertEqual(entry.plotted, 26)
    }
}
