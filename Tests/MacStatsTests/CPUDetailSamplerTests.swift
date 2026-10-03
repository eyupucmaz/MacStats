import Darwin
import XCTest
@testable import MacStats

/// `CPUDetailSampler` driven by a scripted source instead of the mach call.
final class CPUDetailSamplerTests: XCTestCase {

    private final class FakeSource: CPUDetailSource {
        private let lock = NSLock()
        private var baseline = false
        private var _resets = 0
        var resets: Int { lock.lock(); defer { lock.unlock() }; return _resets }

        func sampleCores() -> [CPUSample?]? {
            lock.lock()
            defer { lock.unlock() }
            guard baseline else {
                baseline = true
                return nil
            }
            return [CPUSample(total: 40, user: 30, system: 10), nil]
        }

        func resetCores() {
            lock.lock()
            baseline = false
            _resets += 1
            lock.unlock()
        }

        func loadAverage() -> CPULoadAverage? { CPULoadAverage(one: 1, five: 2, fifteen: 3) }
        func thermalState() -> ProcessInfo.ThermalState { .fair }
    }

    func testFirstReadingHasNoCoresThenCoresFollow() {
        let sampler = CPUDetailSampler(source: FakeSource())
        let first = sampler.sampleNow()
        XCTAssertNil(first.cores)
        XCTAssertEqual(first.loadAverage, CPULoadAverage(one: 1, five: 2, fifteen: 3))
        XCTAssertEqual(first.thermalState, .fair)
        XCTAssertEqual(sampler.sampleNow().cores?.count, 2)
    }

    func testStartDeliversAtOnceOnMainAndStopEndsDelivery() {
        let source = FakeSource()
        let sampler = CPUDetailSampler(source: source)
        let first = expectation(description: "immediate reading")
        let withCores = expectation(description: "reading with cores")
        var readings: [CPUDetailReading] = []
        sampler.start(interval: 0.5) { reading in
            XCTAssertTrue(Thread.isMainThread)
            readings.append(reading)
            if readings.count == 1 { first.fulfill() }
            if readings.count == 2 { withCores.fulfill() }
        }
        XCTAssertTrue(sampler.isRunning)
        sampler.start(interval: 0.5) { _ in XCTFail("a second start is a no-op") }
        wait(for: [first], timeout: 2)
        XCTAssertNil(readings[0].cores, "the immediate reading only sets the baseline")
        wait(for: [withCores], timeout: 5)
        XCTAssertEqual(readings[1].cores?.count, 2)

        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
        let countAtStop = readings.count
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(readings.count, countAtStop)
        XCTAssertGreaterThanOrEqual(source.resets, 2, "start and stop both drop the baseline")
    }
}
