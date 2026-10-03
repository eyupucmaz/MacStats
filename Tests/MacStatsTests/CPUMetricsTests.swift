import Darwin
import XCTest
@testable import MacStats

/// Tick-delta maths and baseline handling of `CPUMetrics`, fed with synthetic
/// `PROCESSOR_CPU_LOAD_INFO` counters instead of the mach call.
final class CPUMetricsTests: XCTestCase {

    /// One core's cumulative counters.
    private struct Core {
        var user: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
        var nice: UInt32 = 0
    }

    /// Lays the cores out the way the kernel does: `CPU_STATE_MAX` counters per core.
    private func ticks(_ cores: [Core]) -> [UInt32] {
        var ticks = [UInt32](repeating: 0, count: cores.count * Int(CPU_STATE_MAX))
        for (index, core) in cores.enumerated() {
            let base = index * Int(CPU_STATE_MAX)
            ticks[base + Int(CPU_STATE_USER)] = core.user
            ticks[base + Int(CPU_STATE_SYSTEM)] = core.system
            ticks[base + Int(CPU_STATE_IDLE)] = core.idle
            ticks[base + Int(CPU_STATE_NICE)] = core.nice
        }
        return ticks
    }

    private func usage(from previous: [Core], to current: [Core]) -> CPUSample? {
        CPUMetrics.usage(previous: ticks(previous), current: ticks(current), coreCount: current.count)
    }

    private func assertUsage(_ sample: CPUSample?, total: Double, user: Double, system: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let sample else { return XCTFail("expected a sample", file: file, line: line) }
        XCTAssertEqual(sample.total, total, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(sample.user, user, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(sample.system, system, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: - Delta maths

    func testUsageIsTheShareOfNonIdleTicks() {
        let sample = usage(from: [Core(user: 100, system: 50, idle: 1_000, nice: 10)],
                           to: [Core(user: 130, system: 60, idle: 1_050, nice: 20)])
        // Deltas: user 30, system 10, idle 50, nice 10 → 100 ticks.
        assertUsage(sample, total: 50, user: 40, system: 10)
    }

    func testCoresArePooled() {
        let sample = usage(from: [Core(), Core()],
                           to: [Core(user: 100, idle: 0), Core(user: 0, idle: 100)])
        assertUsage(sample, total: 50, user: 50, system: 0)
    }

    func testIdleMachineReadsZero() {
        let sample = usage(from: [Core(user: 5, system: 5, idle: 0)],
                           to: [Core(user: 5, system: 5, idle: 100)])
        assertUsage(sample, total: 0, user: 0, system: 0)
    }

    func testNoElapsedTicksIsNotAReading() {
        let core = Core(user: 10, system: 10, idle: 10, nice: 10)
        XCTAssertNil(usage(from: [core], to: [core]))
    }

    func testWrappedCountersStillGiveTheTrueDelta() {
        let nearMax = UInt32.max - 9
        let sample = usage(from: [Core(user: nearMax, system: 0, idle: nearMax, nice: 0)],
                           to: [Core(user: 10, system: 0, idle: 30, nice: 0)])
        // user: 20 ticks across the wrap, idle: 40 ticks across the wrap.
        assertUsage(sample, total: 20.0 / 60 * 100, user: 20.0 / 60 * 100, system: 0)
    }

    func testOneCounterWrappingDoesNotInflateTheOthers() {
        let sample = usage(from: [Core(user: 0, system: UInt32.max, idle: 0, nice: 0)],
                           to: [Core(user: 0, system: 0, idle: 99, nice: 0)])
        // system advanced by exactly one tick through the wrap.
        assertUsage(sample, total: 1, user: 0, system: 1)
    }

    func testMismatchedSnapshotsAreRejected() {
        let one = ticks([Core(user: 1)])
        XCTAssertNil(CPUMetrics.usage(previous: one, current: ticks([Core(user: 2), Core()]), coreCount: 2))
        XCTAssertNil(CPUMetrics.usage(previous: one, current: one, coreCount: 0))
    }

    // MARK: - Per core

    func testCoreUsagesKeepEachCoreSeparate() {
        let loads = CPUMetrics.coreUsages(previous: ticks([Core(), Core(), Core(user: 5, idle: 5)]),
                                          current: ticks([Core(user: 75, system: 25, idle: 0),
                                                          Core(idle: 100),
                                                          Core(user: 5, idle: 5)]),
                                          coreCount: 3)
        XCTAssertEqual(loads.count, 3)
        assertUsage(loads[0], total: 100, user: 75, system: 25)
        assertUsage(loads[1], total: 0, user: 0, system: 0)
        XCTAssertNil(loads[2], "a core with no elapsed ticks has no reading")
    }

    func testPooledUsageIsUnchangedByThePerCoreRefactor() {
        let previous = [Core(user: 10, idle: 10), Core(system: 3, idle: 7)]
        let current = [Core(user: 40, idle: 80), Core(system: 13, idle: 17, nice: 20)]
        // user 30 + nice 20 = 50, system 10, idle 80 → 140 ticks.
        assertUsage(usage(from: previous, to: current), total: 60.0 / 140 * 100,
                    user: 50.0 / 140 * 100, system: 10.0 / 140 * 100)
    }

    func testCoreUsagesRejectMismatchedSnapshots() {
        XCTAssertEqual(CPUMetrics.coreUsages(previous: ticks([Core()]), current: ticks([Core(), Core()]),
                                             coreCount: 2).count, 0)
    }

    func testUpdateCoresNeedsABaseline() {
        let metrics = CPUMetrics()
        XCTAssertNil(metrics.updateCores(ticks: ticks([Core(), Core()]), coreCount: 2))
        let loads = metrics.updateCores(ticks: ticks([Core(user: 10, idle: 10), Core(idle: 20)]), coreCount: 2)
        XCTAssertEqual(loads?.count, 2)
        assertUsage(loads?[0] ?? nil, total: 50, user: 50, system: 0)
        assertUsage(loads?[1] ?? nil, total: 0, user: 0, system: 0)
    }

    // MARK: - Baselines

    func testFirstUpdateOnlyStoresTheBaseline() {
        let metrics = CPUMetrics()
        XCTAssertNil(metrics.update(ticks: ticks([Core(user: 10, idle: 10)]), coreCount: 1))
        assertUsage(metrics.update(ticks: ticks([Core(user: 20, idle: 20)]), coreCount: 1),
                    total: 50, user: 50, system: 0)
    }

    func testEachUpdateBecomesTheNextBaseline() {
        let metrics = CPUMetrics()
        _ = metrics.update(ticks: ticks([Core()]), coreCount: 1)
        _ = metrics.update(ticks: ticks([Core(user: 100, idle: 0)]), coreCount: 1)
        assertUsage(metrics.update(ticks: ticks([Core(user: 100, idle: 100)]), coreCount: 1),
                    total: 0, user: 0, system: 0)
    }

    func testCoreCountChangeRestartsTheBaseline() {
        let metrics = CPUMetrics()
        _ = metrics.update(ticks: ticks([Core()]), coreCount: 1)
        XCTAssertNil(metrics.update(ticks: ticks([Core(user: 10), Core(idle: 10)]), coreCount: 2))
        assertUsage(metrics.update(ticks: ticks([Core(user: 20), Core(idle: 20)]), coreCount: 2),
                    total: 50, user: 50, system: 0)
    }

    func testResetDropsTheBaseline() {
        let metrics = CPUMetrics()
        _ = metrics.update(ticks: ticks([Core()]), coreCount: 1)
        metrics.reset()
        XCTAssertNil(metrics.update(ticks: ticks([Core(user: 10, idle: 10)]), coreCount: 1))
    }

    // MARK: - Live

    func testLiveSamplingNeedsABaselineThenStaysInRange() {
        let metrics = CPUMetrics()
        XCTAssertNil(metrics.sample(), "the first sample has no baseline")
        XCTAssertGreaterThan(metrics.coreCount, 0)
        // Consecutive calls may see no elapsed ticks; only check a reading when there is one.
        if let sample = metrics.sample() {
            XCTAssertTrue((0 ... 100).contains(sample.total))
            XCTAssertLessThanOrEqual(sample.user + sample.system, sample.total + 1e-9)
        }
    }
}
