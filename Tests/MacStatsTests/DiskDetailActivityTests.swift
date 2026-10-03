import XCTest
@testable import MacStats

/// Parsing of IOBlockStorageDriver statistics, rate derivation and the Disk page's
/// activity sampler, driven by scripted counters and a fake clock.
final class DiskDetailActivityTests: XCTestCase {

    private static let second: UInt64 = 1_000_000_000

    private func statistics(read: UInt64, write: UInt64, readOps: UInt64 = 0, writeOps: UInt64 = 0) -> [String: Any] {
        ["Bytes (Read)": NSNumber(value: read), "Bytes (Write)": NSNumber(value: write),
         "Operations (Read)": NSNumber(value: readOps), "Operations (Write)": NSNumber(value: writeOps),
         "Errors (Read)": NSNumber(value: 0)]
    }

    // MARK: - Parsing

    func testCountersAreReadFromTheStatisticsDictionary() {
        let counters = DiskIOStatistics.counters(from: statistics(read: 8_797_439_414_272, write: 3_787_083_821_056,
                                                                  readOps: 488_929_128, writeOps: 150_659_793))
        XCTAssertEqual(counters, DiskIOCounters(readBytes: 8_797_439_414_272, writeBytes: 3_787_083_821_056,
                                                readOperations: 488_929_128, writeOperations: 150_659_793))
    }

    func testMissingOperationCountersReadAsZeroButMissingBytesAreNoReading() {
        XCTAssertEqual(DiskIOStatistics.counters(from: ["Bytes (Read)": NSNumber(value: 10)]),
                       DiskIOCounters(readBytes: 10))
        XCTAssertNil(DiskIOStatistics.counters(from: ["Operations (Read)": NSNumber(value: 10)]))
        XCTAssertNil(DiskIOStatistics.counters(from: ["Bytes (Read)": "10"]))
    }

    func testSumSkipsDiskImagesSoTheirIOIsNotCountedTwice() {
        let drivers = [
            DiskIOStatistics.Driver(statistics: statistics(read: 100, write: 50, readOps: 4, writeOps: 2),
                                    interconnect: "Apple Fabric"),
            DiskIOStatistics.Driver(statistics: statistics(read: 9_000, write: 9_000),
                                    interconnect: "Virtual Interface"),
            DiskIOStatistics.Driver(statistics: statistics(read: 10, write: 5, readOps: 1, writeOps: 1),
                                    interconnect: nil),
            DiskIOStatistics.Driver(statistics: [:], interconnect: "USB"),
        ]
        XCTAssertEqual(DiskIOStatistics.sum(drivers),
                       DiskIOCounters(readBytes: 110, writeBytes: 55, readOperations: 5, writeOperations: 3))
    }

    func testSumIsNilWithoutAnyPhysicalDrive() {
        XCTAssertNil(DiskIOStatistics.sum([]))
        XCTAssertNil(DiskIOStatistics.sum([.init(statistics: statistics(read: 1, write: 1),
                                                 interconnect: "Virtual Interface")]))
    }

    // MARK: - Rates

    func testRatesAreDeltasOverElapsedTime() {
        let before = DiskIOCounters(readBytes: 1_000, writeBytes: 2_000, readOperations: 10, writeOperations: 20)
        let after = DiskIOCounters(readBytes: 3_000, writeBytes: 2_500, readOperations: 30, writeOperations: 21)
        XCTAssertEqual(DiskIOStatistics.rates(from: before, to: after, elapsed: 2),
                       DiskIORates(readBytesPerSecond: 1_000, writeBytesPerSecond: 250,
                                   readOperationsPerSecond: 10, writeOperationsPerSecond: 0.5))
    }

    /// An ejected drive takes its counters with it: no traffic, not a negative rate.
    func testShrinkingCountersReadAsNoTraffic() throws {
        let before = DiskIOCounters(readBytes: 5_000, writeBytes: 5_000, readOperations: 50, writeOperations: 50)
        let after = DiskIOCounters(readBytes: 1_000, writeBytes: 6_000, readOperations: 10, writeOperations: 60)
        let rates = try XCTUnwrap(DiskIOStatistics.rates(from: before, to: after, elapsed: 1))
        XCTAssertEqual(rates.readBytesPerSecond, 0)
        XCTAssertEqual(rates.writeBytesPerSecond, 1_000)
        XCTAssertEqual(rates.readOperationsPerSecond, 0)
        XCTAssertEqual(rates.writeOperationsPerSecond, 10)
    }

    func testNoRatesWithoutElapsedTime() {
        let counters = DiskIOCounters(readBytes: 1)
        XCTAssertNil(DiskIOStatistics.rates(from: counters, to: counters, elapsed: 0))
        XCTAssertNil(DiskIOStatistics.rates(from: counters, to: counters, elapsed: .nan))
    }

    // MARK: - Sampler

    /// Scripted counters and a manual monotonic clock.
    private final class Script {
        var readings: [DiskIOCounters?]
        var time: UInt64 = 100 * DiskDetailActivityTests.second
        init(_ readings: [DiskIOCounters?]) { self.readings = readings }

        func sampler() -> DiskActivitySampler {
            DiskActivitySampler(readCounters: { self.readings.isEmpty ? nil : self.readings.removeFirst() },
                                now: { self.time })
        }
    }

    func testFirstSampleCarriesTotalsThenRatesFollow() throws {
        let script = Script([DiskIOCounters(readBytes: 1_000, writeBytes: 0, readOperations: 1),
                             DiskIOCounters(readBytes: 3_000, writeBytes: 500, readOperations: 5)])
        let sampler = script.sampler()

        let first = try XCTUnwrap(sampler.sampleNow())
        XCTAssertEqual(first.totals.readBytes, 1_000)
        XCTAssertNil(first.rates)

        script.time += 2 * Self.second
        let second = try XCTUnwrap(sampler.sampleNow())
        XCTAssertEqual(second.totals.readBytes, 3_000)
        XCTAssertEqual(second.rates?.readBytesPerSecond, 1_000)
        XCTAssertEqual(second.rates?.writeBytesPerSecond, 250)
        XCTAssertEqual(second.rates?.readOperationsPerSecond, 2)
    }

    func testAFailedReadDropsTheBaseline() throws {
        let script = Script([DiskIOCounters(readBytes: 1_000), nil, DiskIOCounters(readBytes: 9_000)])
        let sampler = script.sampler()
        XCTAssertNotNil(sampler.sampleNow())
        script.time += Self.second
        XCTAssertNil(sampler.sampleNow())
        script.time += Self.second
        // Not 8 000 B over 2 s: the failed tick broke the interval.
        XCTAssertNil(try XCTUnwrap(sampler.sampleNow()).rates)
    }

    func testStartDeliversOnMainAndStopEndsDelivery() {
        let script = Script(Array(repeating: DiskIOCounters(readBytes: 1), count: 50))
        let sampler = script.sampler()
        let delivered = expectation(description: "first report")
        delivered.assertForOverFulfill = false
        sampler.start(interval: 0.5) { report in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(report?.totals.readBytes, 1)
            delivered.fulfill()
        }
        XCTAssertTrue(sampler.isRunning)
        wait(for: [delivered], timeout: 2)
        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
    }
}
