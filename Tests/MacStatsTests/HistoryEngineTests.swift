import XCTest
@testable import MacStats

/// Scripted readings for the engine, like the fake in StatsEngineTests. Called on the
/// engine's sampler queue; tests only touch it between `sampleNow()` calls.
private final class ScriptedSampler: StatsSampler {
    var readings: [StatsReading] = []
    var fallback = StatsReading(memoryUsed: 1, memoryTotal: 2)

    func primeBaselines() {}
    func resetBaselines() {}

    func read() -> StatsReading {
        readings.isEmpty ? fallback : readings.removeFirst()
    }
}

/// A settable clock shared by the sampler queue (stamping) and the test (advancing).
private final class TestClock {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current.addTimeInterval(seconds)
        lock.unlock()
    }
}

/// History recorded by `StatsEngine`: every delivered tick appends the core series.
@MainActor
final class HistoryEngineTests: XCTestCase {
    private var sampler: ScriptedSampler!
    private var clock: TestClock!
    private var engine: StatsEngine!

    override func setUp() async throws {
        try await super.setUp()
        sampler = ScriptedSampler()
        clock = TestClock()
        let clock = clock!
        engine = StatsEngine(sampler: sampler, clock: { clock.now })
    }

    override func tearDown() async throws {
        engine.stop()
        engine.waitUntilIdle()
        try await super.tearDown()
    }

    private func flushMain() {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
    }

    private func fullReading(cpu: Double = 10) -> StatsReading {
        StatsReading(cpuUsage: cpu, cpuUser: cpu * 0.75, cpuSystem: cpu * 0.25, gpuUsage: 20,
                     memoryUsed: 4_000, memoryTotal: 8_000, memoryPressure: 30,
                     disk: DiskSample(usedBytes: 300, totalBytes: 500),
                     network: NetworkSample(downBytesPerSecond: 1_000, upBytesPerSecond: 500),
                     batteryLevel: 80, batteryState: "Discharging",
                     fanRPM: 2_000, temperature: 45)
    }

    /// Samples each reading one second apart, then delivers them to the main thread.
    private func tick(_ readings: [StatsReading]) {
        for reading in readings {
            sampler.readings = [reading]
            engine.sampleNow()
            clock.advance(1)
        }
        flushMain()
    }

    private func values(_ id: String) -> [Double?] {
        engine.history.series(id, range: .oneMinute, now: clock.now)?.points.map(\.value) ?? []
    }

    func testEveryCoreSeriesIsRecordedWithItsUnit() {
        tick([fullReading()])
        let expected: [(String, MetricUnit, Double)] = [
            (MetricSeriesID.cpuTotal, .percent, 10),
            (MetricSeriesID.cpuUser, .percent, 7.5),
            (MetricSeriesID.cpuSystem, .percent, 2.5),
            (MetricSeriesID.gpuUtilization, .percent, 20),
            (MetricSeriesID.memoryUsed, .memory, 4_000),
            (MetricSeriesID.memoryPressure, .percent, 30),
            (MetricSeriesID.batteryLevel, .percent, 80),
            (MetricSeriesID.diskUsed, .bytes, 300),
            (MetricSeriesID.networkDown, .bytesPerSecond, 1_000),
            (MetricSeriesID.networkUp, .bytesPerSecond, 500),
            (MetricSeriesID.fanRPM, .rpm, 2_000),
            (MetricSeriesID.temperaturePrimary, .celsius, 45),
        ]
        for (id, unit, value) in expected {
            let series = engine.history.series(id, range: .oneMinute, now: clock.now)
            XCTAssertEqual(series?.unit, unit, id)
            XCTAssertEqual(series?.points.map(\.value), [value], id)
        }
    }

    func testUnavailableMetricsAreSkippedNotRecordedAsZero() {
        var reading = fullReading()
        reading.gpuUsage = nil
        reading.fanRPM = nil
        reading.temperature = nil
        reading.batteryLevel = 0
        reading.batteryState = "AC Power"
        reading.disk = nil
        reading.network = nil
        tick([reading])

        for id in [MetricSeriesID.gpuUtilization, MetricSeriesID.fanRPM, MetricSeriesID.temperaturePrimary,
                   MetricSeriesID.batteryLevel, MetricSeriesID.diskUsed,
                   MetricSeriesID.networkDown, MetricSeriesID.networkUp] {
            XCTAssertFalse(engine.history.contains(id), "\(id) must not be recorded")
        }
        XCTAssertEqual(values(MetricSeriesID.cpuTotal), [10])
    }

    func testCPUWithoutABaselineIsSkippedAlthoughTheSnapshotKeepsTheLastValue() {
        var noBaseline = fullReading()
        noBaseline.cpuUsage = nil
        noBaseline.cpuUser = nil
        noBaseline.cpuSystem = nil
        tick([fullReading(cpu: 40), noBaseline])

        XCTAssertEqual(engine.snapshot.cpuUsage, 40)
        XCTAssertEqual(values(MetricSeriesID.cpuTotal), [40])
        XCTAssertEqual(values(MetricSeriesID.memoryUsed).count, 2)
    }

    func testFailedMemoryQueryIsSkipped() {
        var reading = fullReading()
        reading.memoryUsed = 0
        tick([reading])
        XCTAssertFalse(engine.history.contains(MetricSeriesID.memoryUsed))
        XCTAssertFalse(engine.history.contains(MetricSeriesID.memoryPressure))
    }

    func testUnchangedReadingsStillAppend() {
        tick([fullReading(), fullReading(), fullReading()])
        XCTAssertEqual(values(MetricSeriesID.cpuTotal), [10, 10, 10])
    }

    func testTicksCoalescedForTheMainThreadAreAllRecorded() {
        let revision = engine.history.revision
        // The main thread is busy running this test, so all three arrive in one delivery.
        tick([fullReading(cpu: 1), fullReading(cpu: 2), fullReading(cpu: 3)])
        XCTAssertEqual(values(MetricSeriesID.cpuTotal), [1, 2, 3])
        XCTAssertEqual(engine.history.revision, revision + 1, "one change notification per delivery")
    }

    func testPauseAndResumeLeaveAGap() {
        tick([fullReading(cpu: 1), fullReading(cpu: 2)])
        engine.stop() // popover closed, no menu bar metrics: the zeroed-rates publish is not recorded
        engine.waitUntilIdle()
        flushMain()
        clock.advance(30)
        tick([fullReading(cpu: 3)])

        XCTAssertEqual(values(MetricSeriesID.cpuTotal), [1, 2, nil, 3])
        XCTAssertEqual(engine.history.statistics(MetricSeriesID.cpuTotal, range: .oneMinute, now: clock.now),
                       SeriesStatistics(min: 1, average: 2, max: 3))
    }

    func testUpdateIntervalResizesTheHistory() {
        XCTAssertEqual(engine.history.sampleInterval, 1)
        engine.setUpdateInterval(5)
        XCTAssertEqual(engine.history.sampleInterval, 5)
        engine.setUpdateInterval(0.1)
        XCTAssertEqual(engine.history.sampleInterval, 0.5)
    }

    func testDetailSamplersCanAddTheirOwnSeries() {
        tick([fullReading()])
        XCTAssertTrue(engine.history.register("disk.read", unit: .bytesPerSecond, interval: 2))
        engine.history.record(1_024, for: "disk.read", unit: .bytesPerSecond, at: clock.now)
        XCTAssertEqual(engine.history.series("disk.read", range: .oneMinute, now: clock.now)?.points,
                       [MetricPoint(date: clock.now, value: 1_024)])
    }
}
