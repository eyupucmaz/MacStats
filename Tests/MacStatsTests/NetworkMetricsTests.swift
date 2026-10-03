import XCTest
@testable import MacStats

/// Throughput maths driven by injected counters and a fake clock.
final class NetworkMetricsTests: XCTestCase {

    /// Feeds `NetworkMetrics` one reading per `sample()` call, one second apart.
    private final class Feed {
        var readings: [[InterfaceCounters]]
        var time: UInt64 = 1_000_000_000

        init(_ readings: [[InterfaceCounters]]) { self.readings = readings }

        func makeMetrics() -> NetworkMetrics {
            NetworkMetrics(readCounters: {
                self.readings.isEmpty ? nil : self.readings.removeFirst()
            }, now: {
                defer { self.time += 1_000_000_000 }
                return self.time
            })
        }
    }

    private func counters(_ name: String, _ input: UInt64, _ output: UInt64) -> InterfaceCounters {
        InterfaceCounters(name: name, inputBytes: input, outputBytes: output)
    }

    func testFirstSampleHasNoBaseline() {
        let feed = Feed([[counters("en0", 100, 100)]])
        XCTAssertNil(feed.makeMetrics().sample())
    }

    func testRateIsDeltaOverElapsedTime() throws {
        let feed = Feed([[counters("en0", 1_000, 500)],
                         [counters("en0", 3_000, 1_500)]])
        let metrics = feed.makeMetrics()
        _ = metrics.sample()
        let sample = try XCTUnwrap(metrics.sample())
        XCTAssertEqual(sample.downBytesPerSecond, 2_000)
        XCTAssertEqual(sample.upBytesPerSecond, 1_000)
    }

    func testCountersPast32BitsAreNotTreatedAsAWrap() throws {
        let base: UInt64 = 0xFFFF_FF00
        let feed = Feed([[counters("en0", base, base)],
                         [counters("en0", base + 1_000, base + 2_000)]])
        let metrics = feed.makeMetrics()
        _ = metrics.sample()
        let sample = try XCTUnwrap(metrics.sample())
        XCTAssertEqual(sample.downBytesPerSecond, 1_000)
        XCTAssertEqual(sample.upBytesPerSecond, 2_000)
    }

    func testOneInterfaceGoingBackwardsDoesNotZeroTheOthers() throws {
        let feed = Feed([[counters("en0", 10_000, 10_000), counters("en1", 50_000, 50_000)],
                         [counters("en0", 12_000, 11_000), counters("en1", 100, 100)]])
        let metrics = feed.makeMetrics()
        _ = metrics.sample()
        let sample = try XCTUnwrap(metrics.sample())
        XCTAssertEqual(sample.downBytesPerSecond, 2_000)
        XCTAssertEqual(sample.upBytesPerSecond, 1_000)
    }

    func testNewInterfaceContributesFromItsSecondReading() throws {
        let feed = Feed([[counters("en0", 0, 0)],
                         [counters("en0", 100, 0), counters("en7", 9_000_000, 9_000_000)],
                         [counters("en0", 200, 0), counters("en7", 9_000_500, 9_000_000)]])
        let metrics = feed.makeMetrics()
        _ = metrics.sample()
        XCTAssertEqual(try XCTUnwrap(metrics.sample()).downBytesPerSecond, 100,
                       "an interface's lifetime total must not show up as one tick")
        XCTAssertEqual(try XCTUnwrap(metrics.sample()).downBytesPerSecond, 600)
    }

    func testVirtualInterfacesAreExcluded() throws {
        let names = ["lo0", "utun3", "ipsec0", "ppp0", "bridge0", "awdl0", "llw0", "ap1",
                     "anpi0", "gif0", "stf0", "vmenet0", "tun0", "tap0"]
        let feed = Feed([[counters("en0", 0, 0)] + names.map { counters($0, 0, 0) },
                         [counters("en0", 1_000, 1_000)] + names.map { counters($0, 5_000_000, 5_000_000) }])
        let metrics = feed.makeMetrics()
        _ = metrics.sample()
        let sample = try XCTUnwrap(metrics.sample())
        XCTAssertEqual(sample.downBytesPerSecond, 1_000, "VPN/bridge/AWDL traffic would be double-counted")
        XCTAssertEqual(sample.upBytesPerSecond, 1_000)
    }

    func testPhysicalAndCellularInterfacesAreCounted() {
        for name in ["en0", "en1", "en12", "pdp_ip0"] {
            XCTAssertTrue(NetworkMetrics.countsTraffic(of: name), name)
        }
    }

    func testResetDropsTheBaseline() {
        let feed = Feed([[counters("en0", 0, 0)], [counters("en0", 1_000, 0)]])
        let metrics = feed.makeMetrics()
        _ = metrics.sample()
        metrics.reset()
        XCTAssertNil(metrics.sample())
    }

    func testFailedReadReturnsNil() {
        XCTAssertNil(Feed([]).makeMetrics().sample())
    }

    func testLiveCountersAreReadable() throws {
        let interfaces = try XCTUnwrap(NetworkMetrics.readInterfaceCounters())
        XCTAssertTrue(interfaces.contains { $0.name == "lo0" }, "every Mac has a loopback interface")
        XCTAssertFalse(interfaces.contains { $0.name.isEmpty })
    }
}
