import Darwin
import XCTest
@testable import MacStats

/// `SMCDetailSampler` (shared by the Fan and Temperature pages) with a scripted read,
/// plus the Fan page's one lenient live check and its cost.
final class FanDetailSamplerTests: XCTestCase {

    func testStartDeliversAtOnceOnMainAndStopEndsDelivery() {
        let lock = NSLock()
        var calls = 0
        let sampler = SMCDetailSampler<Int>(label: "test.SMCDetailSampler") {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls
        }
        let first = expectation(description: "immediate reading")
        let second = expectation(description: "next reading")
        var readings: [Int] = []
        sampler.start(interval: 0.5) { reading in
            XCTAssertTrue(Thread.isMainThread)
            readings.append(reading)
            if readings.count == 1 { first.fulfill() }
            if readings.count == 2 { second.fulfill() }
        }
        XCTAssertTrue(sampler.isRunning)
        sampler.start(interval: 0.5) { _ in XCTFail("a second start is a no-op") }
        wait(for: [first], timeout: 2)
        XCTAssertEqual(readings, [1])
        wait(for: [second], timeout: 5)

        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
        let countAtStop = readings.count
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(readings.count, countAtStop)
    }

    func testRestartAfterStopDeliversAgain() {
        let sampler = SMCDetailSampler<String>(label: "test.SMCDetailSampler.restart") { "reading" }
        sampler.start(interval: 1) { _ in }
        sampler.stop()
        let delivered = expectation(description: "delivered after restart")
        sampler.start(interval: 1) { reading in
            XCTAssertEqual(reading, "reading")
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        sampler.stop()
        XCTAssertEqual(sampler.sampleNow(), "reading")
    }

    /// Lenient: fanless Macs, CI runners and VMs have no fans. Prints the cost quoted
    /// in `FanDetailModel`'s documentation.
    func testLiveReadAndSampleCost() {
        let source = LiveFanDetailSource()
        let report = FanDetailReader.read(from: source)
        for fan in report.fans {
            if let current = fan.current { XCTAssertTrue((0...20_000).contains(current)) }
            if let maximum = fan.maximum, let minimum = fan.minimum { XCTAssertLessThanOrEqual(minimum, maximum) }
        }
        if let count = report.count { XCTAssertLessThanOrEqual(report.fans.count, count) }
        print("FanDetailReader live: \(report)")

        let runs = 50
        let start = Self.processCPUNanoseconds()
        for _ in 0..<runs { _ = FanDetailReader.read(from: source) }
        let perSample = Double(Self.processCPUNanoseconds() - start) / Double(runs) / 1_000_000
        print(String(format: "FanDetailReader cost: %.3f ms CPU per sample = %.4f %% of one core at 1 s",
                     perSample, perSample / 1_000 * 100))
        XCTAssertLessThan(perSample, 50, "a sample should be far cheaper than its interval")
    }

    static func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func nanoseconds(_ time: timeval) -> UInt64 { UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000 }
        return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
    }
}
