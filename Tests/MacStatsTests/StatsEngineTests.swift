import Combine
import XCTest
@testable import MacStats

/// Hands the engine scripted readings and records how it was driven. Called on the
/// engine's sampler queue; tests read the counters after `waitUntilIdle()`.
private final class FakeSampler: StatsSampler {
    var readings: [StatsReading] = []
    var fallback = StatsReading(memoryUsed: 1, memoryTotal: 2)
    var onRead: () -> Void = {}
    private(set) var primeCount = 0
    private(set) var resetCount = 0
    private(set) var readCount = 0

    func primeBaselines() { primeCount += 1 }
    func resetBaselines() { resetCount += 1 }

    func read() -> StatsReading {
        readCount += 1
        onRead()
        return readings.isEmpty ? fallback : readings.removeFirst()
    }
}

/// Engine behaviour driven by `FakeSampler`: no hardware, no fixed sleeps. Main-thread
/// deliveries are awaited with expectations, never by spinning the run loop for a while.
@MainActor
final class StatsEngineTests: XCTestCase {
    private var sampler: FakeSampler!
    private var engine: StatsEngine!
    private var published: [StatsSnapshot] = []
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        sampler = FakeSampler()
        engine = StatsEngine(sampler: sampler)
        published = []
        // `$snapshot` replays the current value on subscription; only count new ones.
        engine.$snapshot.dropFirst()
            .sink { [unowned self] in self.published.append($0) }
            .store(in: &cancellables)
    }

    override func tearDown() async throws {
        engine.stop()
        engine.waitUntilIdle()
        cancellables.removeAll()
        try await super.tearDown()
    }

    /// Runs everything already queued on the main thread, including the engine's
    /// delivery block, which was enqueued before this one.
    private func flushMain() {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
    }

    private func reading(cpu: Double? = 10, gpu: Double? = 20) -> StatsReading {
        StatsReading(cpuUsage: cpu, gpuUsage: gpu,
                     memoryUsed: 4_000, memoryTotal: 8_000,
                     disk: DiskSample(usedBytes: 300, totalBytes: 500),
                     network: NetworkSample(downBytesPerSecond: 1_000, upBytesPerSecond: 500),
                     batteryLevel: 80, batteryState: "Discharging",
                     fanRPM: 2_000, temperature: 45)
    }

    // MARK: - Publishing

    func testSampleIsPublishedOnTheMainThread() {
        sampler.readings = [reading()]
        engine.sampleNow()
        flushMain()

        XCTAssertEqual(published.count, 1)
        let s = engine.snapshot
        XCTAssertEqual(s.cpuUsage, 10)
        XCTAssertEqual(s.gpuUsage, 20)
        XCTAssertTrue(s.isGPUAvailable)
        XCTAssertEqual(s.memoryUsed, 4_000)
        XCTAssertEqual(s.memoryTotal, 8_000)
        XCTAssertEqual(s.diskUsedBytes, 300)
        XCTAssertEqual(s.diskTotalBytes, 500)
        XCTAssertEqual(s.networkDownBytes, 1_000)
        XCTAssertEqual(s.networkUpBytes, 500)
        XCTAssertEqual(s.batteryLevel, 80)
        XCTAssertEqual(s.fanRPM, 2_000)
        XCTAssertEqual(s.temperature, 45)
    }

    func testTicksQueuedWhileMainIsBusyCoalesceIntoOneUpdate() {
        sampler.readings = [reading(cpu: 1), reading(cpu: 2), reading(cpu: 3)]
        // The main thread is "busy" running this test, so none of these can be delivered yet.
        engine.sampleNow()
        engine.sampleNow()
        engine.sampleNow()
        flushMain()

        XCTAssertEqual(published.map(\.cpuUsage), [3], "only the newest snapshot should reach the main thread")
    }

    func testUnchangedReadingIsNotRepublished() {
        sampler.readings = [reading(), reading()]
        engine.sampleNow()
        flushMain()
        engine.sampleNow()
        flushMain()

        XCTAssertEqual(published.count, 1)
    }

    // MARK: - Reading → snapshot

    func testUnreadableGPUIsReportedUnavailableNotZeroPercent() {
        sampler.readings = [reading(gpu: nil)]
        engine.sampleNow()
        flushMain()

        XCTAssertFalse(engine.snapshot.isGPUAvailable)
        XCTAssertEqual(engine.snapshot.gpuUsage, 0)
    }

    func testMissingSensorsAreUnavailable() {
        var s = StatsSnapshot()
        var r = reading()
        r.fanRPM = nil
        r.temperature = nil
        s.apply(r)
        XCTAssertFalse(s.isFanAvailable)
        XCTAssertEqual(s.fanRPM, 0)
        XCTAssertFalse(s.isTemperatureAvailable)
        XCTAssertEqual(s.temperature, 0)
    }

    func testMissingRatesAndDiskKeepThePreviousValue() {
        var s = StatsSnapshot()
        s.apply(reading())
        s.apply(StatsReading(cpuUsage: nil, memoryUsed: 1, memoryTotal: 2, disk: nil, network: nil))
        XCTAssertEqual(s.cpuUsage, 10, "a CPU sample without a baseline must not reset the value")
        XCTAssertEqual(s.diskTotalBytes, 500, "a failed disk query must keep the last capacity")
        XCTAssertEqual(s.networkDownBytes, 1_000)
        XCTAssertEqual(s.memoryUsed, 1)
    }

    func testBatteryAvailability() {
        XCTAssertTrue(StatsSnapshot(batteryLevel: 50, batteryState: "Charging").isBatteryAvailable)
        XCTAssertFalse(StatsSnapshot(batteryLevel: 0, batteryState: "AC Power").isBatteryAvailable)
        XCTAssertFalse(StatsSnapshot(batteryLevel: 50, batteryState: "Unknown").isBatteryAvailable)
    }

    // MARK: - Lifecycle

    func testRepeatedStartCreatesOneTimer() {
        for _ in 0 ..< 5 { engine.start() }
        engine.waitUntilIdle()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(sampler.primeCount, 1, "each timer creation primes the baselines once")
    }

    func testStopCancelsTheTimerAndDropsBaselines() {
        engine.start()
        engine.stop()
        engine.stop()
        engine.waitUntilIdle()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(sampler.resetCount, 2)
    }

    func testStopBeforeStartIsSafe() {
        engine.stop()
        engine.waitUntilIdle()
        XCTAssertFalse(engine.isRunning)
    }

    func testStopZeroesRatesButKeepsLevels() {
        sampler.readings = [reading()]
        engine.sampleNow()
        engine.stop()
        engine.waitUntilIdle()
        flushMain()

        let s = engine.snapshot
        XCTAssertEqual(s.cpuUsage, 0)
        XCTAssertEqual(s.gpuUsage, 0)
        XCTAssertEqual(s.networkDownBytes, 0)
        XCTAssertEqual(s.networkUpBytes, 0)
        XCTAssertEqual(s.memoryUsed, 4_000)
        XCTAssertEqual(s.diskTotalBytes, 500)
    }

    func testTimerSamplesWhileRunning() {
        let sampled = expectation(description: "timer fired")
        sampled.assertForOverFulfill = false
        sampler.onRead = { sampled.fulfill() }
        engine.setUpdateInterval(0.5)
        engine.start()
        wait(for: [sampled], timeout: 5)
    }

    // MARK: - Update interval

    func testUnchangedIntervalDoesNotRestartTheTimer() {
        engine.setUpdateInterval(2)
        engine.start()
        engine.setUpdateInterval(2)
        engine.setUpdateInterval(2.0000)
        engine.waitUntilIdle()
        XCTAssertEqual(sampler.primeCount, 1)
    }

    func testChangedIntervalRestartsARunningTimer() {
        engine.start()
        engine.setUpdateInterval(5)
        engine.waitUntilIdle()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(sampler.primeCount, 2)
    }

    func testIntervalChangeWhileStoppedDoesNotStart() {
        engine.setUpdateInterval(5)
        engine.waitUntilIdle()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(sampler.primeCount, 0)
    }

    func testOutOfRangeIntervalsKeepTheEngineRunning() {
        engine.start()
        for interval in [-100.0, -1.0, 0.0, 0.0001, 1e9, .greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            engine.setUpdateInterval(interval)
        }
        XCTAssertTrue(engine.isRunning)
    }

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
}

/// Smoke tests against real hardware. They only assert invariants that hold on
/// every Mac — nothing assumes a fan, a battery, a readable GPU or SMC access — and
/// wait on events rather than fixed sleeps.
@MainActor
final class StatsEngineLiveTests: XCTestCase {

    func testSharedReturnsTheSameInstance() {
        XCTAssertTrue(StatsEngine.shared === StatsEngine.shared)
    }

    func testLiveSamplerReadsPlausibleValues() {
        let sampler = LiveStatsSampler()
        sampler.primeBaselines()
        let r = sampler.read()

        XCTAssertEqual(r.memoryTotal, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(r.memoryUsed, r.memoryTotal)
        if let cpu = r.cpuUsage { XCTAssertTrue((0 ... 100).contains(cpu), "cpu \(cpu)") }
        if let gpu = r.gpuUsage { XCTAssertTrue((0 ... 100).contains(gpu), "gpu \(gpu)") }
        XCTAssertNotNil(r.disk, "startup volume capacity must be readable")
        if let disk = r.disk {
            XCTAssertGreaterThan(disk.totalBytes, 0)
            XCTAssertLessThanOrEqual(disk.usedBytes, disk.totalBytes)
        }
        XCTAssertTrue((0 ... 100).contains(r.batteryLevel))
        XCTAssertFalse(r.batteryState.isEmpty)
        if let rpm = r.fanRPM { XCTAssertGreaterThanOrEqual(rpm, 0) }
        if let celsius = r.temperature { XCTAssertTrue(celsius > 0 && celsius < 150, "temperature \(celsius)") }
    }

    func testSharedEnginePublishesWhileRunning() {
        let engine = StatsEngine.shared
        let published = expectation(description: "a sample was published")
        let subscription = engine.$snapshot
            .dropFirst()
            .first { $0.memoryTotal > 0 }
            .sink { _ in published.fulfill() }
        engine.start()
        wait(for: [published], timeout: 10)
        engine.stop()
        subscription.cancel()

        let s = engine.snapshot
        XCTAssertEqual(s.memoryTotal, ProcessInfo.processInfo.physicalMemory)
        XCTAssertTrue((0 ... 100).contains(s.cpuUsage))
        XCTAssertTrue((0 ... 100).contains(s.gpuUsage))
        XCTAssertTrue(s.networkDownBytes.isFinite && s.networkDownBytes >= 0)
        XCTAssertTrue(s.networkUpBytes.isFinite && s.networkUpBytes >= 0)
    }
}
