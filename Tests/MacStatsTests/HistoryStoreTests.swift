import Darwin
import XCTest
@testable import MacStats

/// `MetricHistory` driven by an injected clock: every date is an offset from `t0`.
@MainActor
final class HistoryStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var now: Date!
    private var history: MetricHistory!

    override func setUp() async throws {
        try await super.setUp()
        now = t0
        history = MetricHistory(sampleInterval: 1, clock: { [unowned self] in self.now })
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Records `values` one second apart starting at `start`, then moves the clock to the last one.
    private func fill(_ values: [Double], id: String = "cpu.total", from start: TimeInterval = 0,
                      step: TimeInterval = 1) {
        for (offset, value) in values.enumerated() {
            history.record(value, for: id, unit: .percent, at: at(start + Double(offset) * step))
        }
        now = at(start + Double(max(values.count - 1, 0)) * step)
    }

    private func values(_ series: MetricSeries?) -> [Double?] { series?.points.map(\.value) ?? [] }

    // MARK: - Recording

    func testUnknownSeriesIsNil() {
        XCTAssertNil(history.series("nope", range: .oneMinute))
        XCTAssertNil(history.statistics("nope", range: .oneMinute))
    }

    func testRecordedSeriesKeepsUnitAndOrder() {
        fill([1, 2, 3])
        let series = history.series("cpu.total", range: .oneMinute)
        XCTAssertEqual(series?.id, "cpu.total")
        XCTAssertEqual(series?.unit, .percent)
        XCTAssertEqual(values(series), [1, 2, 3])
        XCTAssertEqual(series?.points.map(\.date), [at(0), at(1), at(2)])
    }

    func testRecordDefaultsToTheClock() {
        now = at(42)
        history.record(7, for: "x", unit: .count)
        XCTAssertEqual(history.series("x", range: .oneMinute)?.points, [MetricPoint(date: at(42), value: 7)])
    }

    func testNonFiniteValuesAreDropped() {
        XCTAssertFalse(history.record(.nan, for: "x", unit: .count, at: at(0)))
        XCTAssertFalse(history.record(.infinity, for: "x", unit: .count, at: at(0)))
        XCTAssertFalse(history.contains("x"))
    }

    func testRevisionBumpsOncePerRecord() {
        let before = history.revision
        fill([1, 2])
        XCTAssertEqual(history.revision, before + 2)
    }

    func testBatchRecordBumpsRevisionOnce() {
        let before = history.revision
        var a = CoreMetricSample(reading: StatsReading(), date: at(0))
        a.cpuTotal = 1
        a.gpuUtilization = 2
        var b = a
        b.date = at(1)
        history.record([a, b])
        XCTAssertEqual(history.revision, before + 1)
        XCTAssertEqual(values(history.series(MetricSeriesID.cpuTotal, range: .oneMinute, now: at(1))), [1, 1])
        XCTAssertEqual(values(history.series(MetricSeriesID.gpuUtilization, range: .oneMinute, now: at(1))), [2, 2])
    }

    func testBackwardsClockStartsTheSeriesOver() {
        fill([1, 2, 3], from: 100)
        history.record(9, for: "cpu.total", unit: .percent, at: at(50))
        now = at(50)
        XCTAssertEqual(values(history.series("cpu.total", range: .oneHour)), [9])
    }

    // MARK: - Capacity

    func testCapacityCoversOneHourAtTheInterval() {
        XCTAssertGreaterThanOrEqual(MetricHistory.capacity(for: 1), 3_600)
        XCTAssertGreaterThanOrEqual(MetricHistory.capacity(for: 0.5), 7_200)
        XCTAssertGreaterThanOrEqual(MetricHistory.capacity(for: 60), 60)
        XCTAssertEqual(MetricHistory.capacity(for: 0.01), MetricHistory.capacity(for: 0.5), "clamped to the minimum")
        XCTAssertEqual(MetricHistory.capacity(for: .nan), MetricHistory.capacity(for: 1))
    }

    func testWrapAroundDropsTheOldestPoints() {
        history.setSampleInterval(60) // capacity 65
        let capacity = MetricHistory.capacity(for: 60)
        fill((0 ..< capacity + 10).map(Double.init), step: 60)
        let series = history.series("cpu.total", range: .oneHour, maxPoints: 1_000)
        // An hour at 60 s holds 61 points, all of them from the newest end.
        XCTAssertEqual(series?.points.last?.value, Double(capacity + 9))
        XCTAssertEqual(series?.points.count, 61)
        XCTAssertEqual(history.statistics("cpu.total", range: .oneHour)?.max, Double(capacity + 9))
    }

    func testIntervalChangeResizesAndKeepsTheNewestPoints() {
        fill((0 ..< 200).map(Double.init))
        let bytesAtOneSecond = history.estimatedMemoryBytes

        history.setSampleInterval(60)
        XCTAssertEqual(history.sampleInterval, 60)
        XCTAssertLessThan(history.estimatedMemoryBytes, bytesAtOneSecond)
        let kept = values(history.series("cpu.total", range: .oneHour, maxPoints: 1_000))
        XCTAssertEqual(kept.count, MetricHistory.capacity(for: 60))
        XCTAssertEqual(kept.last, 199)
        XCTAssertEqual(kept.first, Double(200 - MetricHistory.capacity(for: 60)))

        history.setSampleInterval(0.5)
        XCTAssertEqual(history.estimatedMemoryBytes,
                       MetricHistory.capacity(for: 0.5) * MemoryLayout<MetricHistory.Entry>.stride)
        XCTAssertEqual(values(history.series("cpu.total", range: .oneHour, maxPoints: 1_000)), kept,
                       "growing must not lose points")
    }

    func testSeriesWithItsOwnIntervalIgnoresStoreResizes() {
        XCTAssertTrue(history.register("process.top", unit: .percent, interval: 2))
        let bytes = history.estimatedMemoryBytes
        history.setSampleInterval(10)
        XCTAssertEqual(history.estimatedMemoryBytes, bytes)
        // Recording later must not reset the series to the store interval.
        history.record(1, for: "process.top", unit: .percent, at: at(0))
        history.record(2, for: "process.top", unit: .percent, at: at(2))
        XCTAssertEqual(history.estimatedMemoryBytes, bytes)
        XCTAssertEqual(values(history.series("process.top", range: .oneMinute, now: at(2))), [1, 2],
                       "2 s apart is on cadence for a 2 s series, not a gap")
    }

    func testSeriesCountIsCapped() {
        for index in 0 ..< MetricHistory.maximumSeriesCount {
            XCTAssertTrue(history.register("s\(index)", unit: .count))
        }
        XCTAssertFalse(history.register("one.too.many", unit: .count))
        XCTAssertFalse(history.record(1, for: "one.too.many", unit: .count))
        history.removeSeries("s0")
        XCTAssertTrue(history.record(1, for: "one.too.many", unit: .count))
    }

    /// Acceptance: memory with every series full, at the fastest refresh interval.
    func testAllSeriesFullStayWithinTheMemoryBudget() {
        history.setSampleInterval(MetricHistory.minimumInterval)
        let capacity = MetricHistory.capacity(for: MetricHistory.minimumInterval)
        let heapBefore = Self.heapBytesInUse()
        for index in 0 ..< MetricHistory.maximumSeriesCount {
            for tick in 0 ..< capacity {
                history.record(Double(tick), for: "series.\(index)", unit: .count, at: at(Double(tick) * 0.5))
            }
        }
        let heapGrowth = Self.heapBytesInUse() - heapBefore
        let estimate = history.estimatedMemoryBytes
        print("MetricHistory full: \(MetricHistory.maximumSeriesCount) series × \(capacity) entries × "
              + "\(MemoryLayout<MetricHistory.Entry>.stride) B = \(estimate) B estimated, \(heapGrowth) B heap growth")
        XCTAssertEqual(estimate, MetricHistory.maximumSeriesCount * capacity * 16)
        XCTAssertLessThanOrEqual(estimate, MetricHistory.memoryBudgetBytes)
        XCTAssertLessThanOrEqual(heapGrowth, MetricHistory.memoryBudgetBytes, "measured, including allocator rounding")
    }

    private static func heapBytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    // MARK: - Range slicing

    func testRangesSliceFromTheEnd() {
        fill((0 ... 3_600).map(Double.init)) // one point per second for an hour; clock at 3600
        XCTAssertEqual(history.statistics("cpu.total", range: .oneMinute)?.min, 3_540)
        XCTAssertEqual(history.statistics("cpu.total", range: .fiveMinutes)?.min, 3_300)
        XCTAssertEqual(history.statistics("cpu.total", range: .fifteenMinutes)?.min, 2_700)
        XCTAssertEqual(history.statistics("cpu.total", range: .oneHour)?.min, 0)
        XCTAssertEqual(history.series("cpu.total", range: .oneMinute, maxPoints: 1_000)?.points.count, 61)
    }

    func testExplicitNowSlicesTheMiddle() {
        fill((0 ..< 600).map(Double.init))
        let series = history.series("cpu.total", range: .oneMinute, now: at(100))
        XCTAssertEqual(series?.points.first?.value, 40)
        XCTAssertEqual(series?.points.last?.value, 100)
    }

    func testStaleSeriesReturnsEmptyPointsNotNil() {
        fill([1, 2, 3])
        now = at(10_000)
        XCTAssertEqual(history.series("cpu.total", range: .oneHour)?.points, [])
        XCTAssertNil(history.statistics("cpu.total", range: .oneHour))
    }

    // MARK: - Statistics

    func testStatisticsMinAverageMax() {
        fill([4, 8, 2, 6])
        XCTAssertEqual(history.statistics("cpu.total", range: .oneMinute),
                       SeriesStatistics(min: 2, average: 5, max: 8))
    }

    func testStatisticsIgnoreGaps() {
        fill([10, 20], from: 0)
        fill([30], from: 30) // 29 s after the last point: stored as a gap
        XCTAssertEqual(history.statistics("cpu.total", range: .oneMinute),
                       SeriesStatistics(min: 10, average: 20, max: 30))
    }

    // MARK: - Gaps

    func testOnCadenceSamplesHaveNoGaps() {
        fill([1, 2, 3], step: 2.5) // exactly 2.5 × interval is still on cadence
        XCTAssertFalse(values(history.series("cpu.total", range: .oneMinute)).contains(nil))
    }

    func testLongPauseIsStoredAsABreak() {
        fill([1, 2])
        fill([3], from: 5) // 4 s after the last point at a 1 s interval
        let points = history.series("cpu.total", range: .oneMinute)?.points ?? []
        XCTAssertEqual(points.map(\.value), [1, 2, nil, 3])
        XCTAssertTrue(points[1].date < points[2].date && points[2].date < points[3].date)
    }

    func testGapThresholdFollowsTheInterval() {
        history.setSampleInterval(5)
        fill([1, 2], step: 5)
        fill([3], from: 15) // 10 s apart is on cadence at 5 s
        fill([4], from: 40) // 25 s apart is a gap
        XCTAssertEqual(values(history.series("cpu.total", range: .oneMinute)), [1, 2, 3, nil, 4])
    }

    // MARK: - Downsampling

    func testSmallRangesAreNotDownsampled() {
        fill((0 ..< 60).map(Double.init))
        XCTAssertEqual(history.series("cpu.total", range: .oneMinute)?.points.count, 60)
    }

    func testDownsamplingCapsPointsAndKeepsExtrema() {
        var input = (0 ... 3_600).map { 50 + sin(Double($0) / 60) * 10 }
        input[1_234] = 99.5 // one-tick spike
        input[2_345] = 0.25 // one-tick dip
        fill(input)

        let series = history.series("cpu.total", range: .oneHour)
        let points = series?.points ?? []
        XCTAssertLessThanOrEqual(points.count, 300)
        XCTAssertGreaterThan(points.count, 250, "most buckets should emit a min and a max")
        XCTAssertEqual(points.compactMap(\.value).max(), 99.5)
        XCTAssertEqual(points.compactMap(\.value).min(), 0.25)
        XCTAssertTrue(points.contains(MetricPoint(date: at(1_234), value: 99.5)), "the spike keeps its time")
        XCTAssertEqual(points.map(\.date), points.map(\.date).sorted(), "points stay in time order")
        XCTAssertEqual(history.statistics("cpu.total", range: .oneHour)?.max, 99.5)
    }

    func testDownsamplingKeepsGapsAndStaysUnderTheCap() {
        fill((0 ..< 1_000).map(Double.init))
        fill((0 ..< 1_000).map { Double($0) + 5_000 }, from: 1_500) // 500 s pause
        let points = history.series("cpu.total", range: .oneHour)?.points ?? []
        XCTAssertLessThanOrEqual(points.count, 300)
        XCTAssertEqual(points.filter { $0.value == nil }.count, 1)
        let gap = points.firstIndex { $0.value == nil }!
        XCTAssertTrue(points[..<gap].allSatisfy { ($0.value ?? 0) < 1_000 }, "only pre-pause values before the break")
        XCTAssertTrue(points[(gap + 1)...].allSatisfy { ($0.value ?? 0) >= 5_000 })
        XCTAssertEqual(points.compactMap(\.value).max(), 5_999)
        XCTAssertEqual(points.compactMap(\.value).min(), 0)
    }

    func testDownsampleRespectsSmallLimits() {
        let entries = (0 ..< 100).map { MetricHistory.Entry(date: at(Double($0)), value: Double($0)) }
        let points = MetricHistory.downsample(entries, from: at(0), to: at(99), maxPoints: 10)
        XCTAssertLessThanOrEqual(points.count, 10)
        XCTAssertEqual(points.first?.value, 0)
        XCTAssertEqual(points.last?.value, 99)
    }
}
