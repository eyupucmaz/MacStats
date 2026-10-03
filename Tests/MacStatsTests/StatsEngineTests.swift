import XCTest
@testable import MacStats

/// Contract tests for `StatsEngine`.
///
/// The engine samples real hardware, so the assertions here only cover
/// invariants that hold on every Mac: ranges, monotonic bounds, the memory
/// total reported by the OS, and lifecycle safety. Nothing here assumes a
/// fan, a battery, a discrete GPU or working SMC access.
@MainActor
final class StatsEngineTests: XCTestCase {

    private var engine: StatsEngine { StatsEngine.shared }

    override func tearDown() async throws {
        StatsEngine.shared.stop()
        try await super.tearDown()
    }

    /// Runs the engine briefly so that at least one sample has been published.
    private func sampleOnce(interval: Double = 0.1) {
        let engine = self.engine
        engine.setUpdateInterval(interval)
        engine.start()
        // Spin the main run loop so a main-thread timer can actually fire.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        engine.stop()
    }

    // MARK: - Singleton

    func testSharedReturnsTheSameInstance() {
        XCTAssertTrue(StatsEngine.shared === StatsEngine.shared)
    }

    // MARK: - Memory

    func testMemoryTotalMatchesProcessInfo() {
        sampleOnce()
        XCTAssertEqual(engine.memoryTotal, ProcessInfo.processInfo.physicalMemory)
    }

    func testMemoryTotalIsNonZero() {
        sampleOnce()
        XCTAssertGreaterThan(engine.memoryTotal, 0)
    }

    func testMemoryUsedDoesNotExceedTotal() {
        sampleOnce()
        XCTAssertLessThanOrEqual(engine.memoryUsed, engine.memoryTotal)
    }

    // MARK: - Percentages

    func testCPUUsageStaysWithinPercentageRange() {
        sampleOnce()
        XCTAssertFalse(engine.cpuUsage.isNaN, "cpuUsage must never be NaN")
        XCTAssertGreaterThanOrEqual(engine.cpuUsage, 0)
        XCTAssertLessThanOrEqual(engine.cpuUsage, 100)
    }

    func testGPUUsageStaysWithinPercentageRange() {
        sampleOnce()
        XCTAssertFalse(engine.gpuUsage.isNaN, "gpuUsage must never be NaN")
        XCTAssertGreaterThanOrEqual(engine.gpuUsage, 0)
        XCTAssertLessThanOrEqual(engine.gpuUsage, 100)
    }

    func testEveryPublishedPercentageStaysInRangeAcrossSamples() {
        let engine = self.engine
        engine.setUpdateInterval(0.1)
        engine.start()
        for _ in 0 ..< 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            XCTAssertTrue((0 ... 100).contains(engine.cpuUsage), "cpuUsage out of range: \(engine.cpuUsage)")
            XCTAssertTrue((0 ... 100).contains(engine.gpuUsage), "gpuUsage out of range: \(engine.gpuUsage)")
        }
        engine.stop()
    }

    // MARK: - Battery

    func testBatteryLevelStaysWithinPercentageRange() {
        sampleOnce()
        XCTAssertGreaterThanOrEqual(engine.batteryLevel, 0)
        XCTAssertLessThanOrEqual(engine.batteryLevel, 100)
    }

    /// A desktop Mac has no battery; the engine must still publish a usable
    /// (non-nil, non-empty) state string rather than an empty placeholder.
    func testBatteryStateIsNonEmpty() {
        sampleOnce()
        XCTAssertFalse(engine.batteryState.isEmpty)
    }

    // MARK: - Throughput counters

    func testThroughputCountersAreNonNegativeAndFinite() {
        sampleOnce()
        for (name, value) in [
            ("networkUpBytes", engine.networkUpBytes),
            ("networkDownBytes", engine.networkDownBytes),
        ] {
            XCTAssertTrue(value.isFinite, "\(name) must be finite, got \(value)")
            XCTAssertGreaterThanOrEqual(value, 0, "\(name) must not be negative")
        }
    }

    // MARK: - Disk capacity

    func testDiskUsageFitsWithinTotal() {
        sampleOnce()
        XCTAssertGreaterThan(engine.diskTotalBytes, 0, "startup volume capacity must be readable")
        XCTAssertLessThanOrEqual(engine.diskUsedBytes, engine.diskTotalBytes)
    }

    // MARK: - Hardware availability

    /// On a fanless Mac (and anywhere SMC access fails) the engine must report
    /// the fan as unavailable and must not invent an RPM figure.
    func testFanRPMIsZeroWhenNoFanIsAvailable() {
        sampleOnce()
        XCTAssertGreaterThanOrEqual(engine.fanRPM, 0)
        if !engine.isFanAvailable {
            XCTAssertEqual(engine.fanRPM, 0)
        }
    }

    /// Likewise for temperature: unavailable means 0, not a fabricated value.
    func testTemperatureIsPlausibleOrReportedUnavailable() {
        sampleOnce()
        XCTAssertFalse(engine.temperature.isNaN, "temperature must never be NaN")
        if engine.isTemperatureAvailable {
            XCTAssertGreaterThan(engine.temperature, 0)
            XCTAssertLessThan(engine.temperature, 150)
        } else {
            XCTAssertEqual(engine.temperature, 0, accuracy: 0.0001)
        }
    }

    // MARK: - Update interval

    func testNormalizedUpdateIntervalUsesOneSecondForNonFiniteInput() {
        XCTAssertEqual(StatsEngine.normalizedUpdateInterval(.nan), 1.0)
        XCTAssertEqual(StatsEngine.normalizedUpdateInterval(.infinity), 1.0)
        XCTAssertEqual(StatsEngine.normalizedUpdateInterval(-.infinity), 1.0)
    }

    func testNormalizedUpdateIntervalClampsFiniteInput() {
        XCTAssertEqual(StatsEngine.normalizedUpdateInterval(-100), 0.5)
        XCTAssertEqual(StatsEngine.normalizedUpdateInterval(10), 10)
        XCTAssertEqual(StatsEngine.normalizedUpdateInterval(1e9), 60)
    }

    func testSetUpdateIntervalAcceptsOutOfRangeValuesWithoutBreakingSampling() {
        let engine = self.engine
        for interval in [-100.0, -1.0, 0.0, 0.0001, 1e9, Double.greatestFiniteMagnitude] {
            engine.setUpdateInterval(interval)
        }
        // Whatever clamping happened, the engine must still run and publish
        // sane values afterwards.
        sampleOnce()
        XCTAssertTrue((0 ... 100).contains(engine.cpuUsage))
        XCTAssertEqual(engine.memoryTotal, ProcessInfo.processInfo.physicalMemory)
    }

    func testSetUpdateIntervalToleratesNonFiniteInput() {
        let engine = self.engine
        engine.setUpdateInterval(.nan)
        engine.setUpdateInterval(.infinity)
        engine.setUpdateInterval(-.infinity)
        engine.setUpdateInterval(1.0)
        sampleOnce()
        XCTAssertTrue((0 ... 100).contains(engine.cpuUsage))
    }

    func testSetUpdateIntervalIsSafeWhileRunning() {
        let engine = self.engine
        engine.start()
        engine.setUpdateInterval(0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        engine.setUpdateInterval(5.0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        engine.stop()
        XCTAssertTrue((0 ... 100).contains(engine.cpuUsage))
    }

    // MARK: - Lifecycle

    func testRepeatedStartIsSafeAndDoesNotLeaveWorkBehindAfterStop() {
        let engine = self.engine
        engine.setUpdateInterval(0.1)
        for _ in 0 ..< 5 {
            engine.start()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        engine.stop()

        // Let any sample that was already in flight when stop() was called
        // finish publishing before taking the baseline.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // After a single stop, no further sampling may occur — if repeated
        // start() had leaked a timer per call, one stop() would not silence it.
        let cpuAfterStop = engine.cpuUsage
        let memoryAfterStop = engine.memoryUsed
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(engine.cpuUsage, cpuAfterStop, accuracy: 0.0001,
                       "cpuUsage changed after stop() — a timer is still running")
        XCTAssertEqual(engine.memoryUsed, memoryAfterStop,
                       "memoryUsed changed after stop() — a timer is still running")
    }

    func testRepeatedStopIsSafe() {
        let engine = self.engine
        engine.start()
        for _ in 0 ..< 5 {
            engine.stop()
        }
        XCTAssertTrue((0 ... 100).contains(engine.cpuUsage))
    }

    func testStopBeforeStartIsSafe() {
        let engine = self.engine
        engine.stop()
        engine.stop()
        XCTAssertTrue((0 ... 100).contains(engine.cpuUsage))
    }

    func testStartStopCyclesAreSafe() {
        let engine = self.engine
        engine.setUpdateInterval(0.1)
        for _ in 0 ..< 3 {
            engine.start()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            engine.stop()
        }
        XCTAssertTrue((0 ... 100).contains(engine.cpuUsage))
        XCTAssertEqual(engine.memoryTotal, ProcessInfo.processInfo.physicalMemory)
    }
}
