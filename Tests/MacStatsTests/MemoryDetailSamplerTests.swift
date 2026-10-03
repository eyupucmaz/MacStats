import XCTest
@testable import MacStats

/// `MemoryDetailSampler` driven by a fake source and clock, plus one lenient live run.
final class MemoryDetailSamplerTests: XCTestCase {

    private final class FakeSource: MemoryDetailSource {
        var physicalMemory: UInt64 = 1_000 * 16_384
        var counterValue: VMCounters? = VMCounters(pageSize: 16_384, wiredPages: 100, internalPages: 200)
        var level: Int32? = 1
        var swap: SwapUsage? = SwapUsage(used: 0, total: 0)

        func counters() -> VMCounters? { counterValue }
        func pressureLevel() -> Int32? { level }
        func swapUsage() -> SwapUsage? { swap }
    }

    private final class Clock {
        var nanoseconds: UInt64 = 1_000_000_000
        func advance(seconds: Double) { nanoseconds += UInt64(seconds * 1_000_000_000) }
    }

    func testFirstSampleHasEverythingButRates() throws {
        let source = FakeSource()
        let sampler = MemoryDetailSampler(source: source, now: { 1 })
        let detail = sampler.sampleNow()
        XCTAssertNil(detail.rates)
        XCTAssertEqual(detail.level, .normal)
        XCTAssertEqual(detail.swap, SwapUsage(used: 0, total: 0))
        XCTAssertEqual(detail.pageSize, 16_384)
        XCTAssertEqual(detail.physicalMemory, 1_000 * 16_384)
        XCTAssertEqual(try XCTUnwrap(detail.breakdown).wired, 100 * 16_384)
    }

    func testSecondSampleHasRatesOverTheElapsedTime() throws {
        let source = FakeSource()
        let clock = Clock()
        let sampler = MemoryDetailSampler(source: source, now: { clock.nanoseconds })
        _ = sampler.sampleNow()
        source.counterValue?.pageIns = 30
        clock.advance(seconds: 2)
        let rates = try XCTUnwrap(sampler.sampleNow().rates)
        XCTAssertEqual(rates.pageIns, 15 * 16_384)
    }

    func testFailedQueriesAreNilNotZero() {
        let source = FakeSource()
        source.counterValue = nil
        source.level = 3
        source.swap = nil
        source.physicalMemory = 0
        let detail = MemoryDetailSampler(source: source, now: { 1 }).sampleNow()
        XCTAssertEqual(detail, MemoryDetail())
    }

    func testFailedReadRestartsTheRateBaseline() {
        let source = FakeSource()
        let clock = Clock()
        let sampler = MemoryDetailSampler(source: source, now: { clock.nanoseconds })
        _ = sampler.sampleNow()
        source.counterValue = nil
        clock.advance(seconds: 1)
        _ = sampler.sampleNow()
        source.counterValue = VMCounters(pageSize: 16_384, pageIns: 99)
        clock.advance(seconds: 1)
        XCTAssertNil(sampler.sampleNow().rates)
    }

    func testStartDeliversRightAwayOnMainAndStopEndsIt() {
        let sampler = MemoryDetailSampler(source: FakeSource())
        let delivered = expectation(description: "first reading")
        sampler.start(interval: 60) { detail in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(detail.level, .normal)
            delivered.fulfill()
        }
        XCTAssertTrue(sampler.isRunning)
        wait(for: [delivered], timeout: 2)
        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
    }

    /// The one live check: values are plausible, and a sample stays cheap. Prints the
    /// per-sample time (`dispatch_sync` runs the work on this thread, so thread CPU
    /// time is the sampler's own cost).
    func testLiveSampleCost() {
        let sampler = MemoryDetailSampler()
        let first = sampler.sampleNow()
        XCTAssertEqual(first.physicalMemory, ProcessInfo.processInfo.physicalMemory)
        XCTAssertNotNil(first.breakdown)
        XCTAssertNotNil(first.pageSize)

        let iterations = 500
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var detail = first
        for _ in 0 ..< iterations { detail = sampler.sampleNow() }
        let perSample = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9 / Double(iterations)
        print("MemoryDetailSampler: \(String(format: "%.1f", perSample * 1_000_000)) µs CPU per sample")
        XCTAssertLessThan(perSample, 0.005, "a sample should take well under 5 ms")
        XCTAssertNotNil(detail.rates)
    }
}
