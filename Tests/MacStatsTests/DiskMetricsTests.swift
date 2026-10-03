import XCTest
@testable import MacStats

/// Cache and fallback behaviour of `DiskMetrics`, driven by a scripted capacity
/// reader and a fake clock. Nothing here queries a real volume.
final class DiskMetricsTests: XCTestCase {

    private static let second: UInt64 = 1_000_000_000

    /// Hands out scripted readings and records how often the volume was queried.
    private final class Volume {
        var readings: [DiskSample?]
        var time: UInt64 = 5 * DiskMetricsTests.second
        private(set) var reads = 0
        private(set) var queriedVolumes: [String] = []

        init(_ readings: [DiskSample?]) { self.readings = readings }

        func makeMetrics(volume: String = "/", refreshInterval: TimeInterval = 10) -> DiskMetrics {
            DiskMetrics(volume: volume, refreshInterval: refreshInterval, readCapacity: { volume in
                self.reads += 1
                self.queriedVolumes.append(volume)
                return self.readings.isEmpty ? nil : self.readings.removeFirst()
            }, now: { self.time })
        }

        func advance(seconds: Double) { time += UInt64(seconds * Double(DiskMetricsTests.second)) }
    }

    private func disk(used: UInt64) -> DiskSample { DiskSample(usedBytes: used, totalBytes: 1_000) }

    private func assertSample(_ sample: DiskSample?, used: UInt64?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sample?.usedBytes, used, file: file, line: line)
        if used != nil { XCTAssertEqual(sample?.totalBytes, 1_000, file: file, line: line) }
    }

    // MARK: - Cache

    func testFirstSampleQueriesTheConfiguredVolume() {
        let volume = Volume([disk(used: 100)])
        let metrics = volume.makeMetrics(volume: "/Volumes/Data")

        assertSample(metrics.sample(), used: 100)
        XCTAssertEqual(volume.queriedVolumes, ["/Volumes/Data"])
    }

    func testReadingIsReusedWithinTheRefreshInterval() {
        let volume = Volume([disk(used: 100), disk(used: 200)])
        let metrics = volume.makeMetrics()

        assertSample(metrics.sample(), used: 100)
        volume.advance(seconds: 1)
        assertSample(metrics.sample(), used: 100)
        volume.advance(seconds: 8.9)
        assertSample(metrics.sample(), used: 100)
        XCTAssertEqual(volume.reads, 1, "a reading younger than 10 s must not hit the volume")
    }

    func testReadingIsRefreshedOnceTheIntervalElapses() {
        let volume = Volume([disk(used: 100), disk(used: 200), disk(used: 300)])
        let metrics = volume.makeMetrics()

        assertSample(metrics.sample(), used: 100)
        volume.advance(seconds: 10)
        assertSample(metrics.sample(), used: 200)
        XCTAssertEqual(volume.reads, 2)

        // The interval restarts from the refresh, not from the first reading.
        volume.advance(seconds: 9)
        assertSample(metrics.sample(), used: 200)
        volume.advance(seconds: 1)
        assertSample(metrics.sample(), used: 300)
        XCTAssertEqual(volume.reads, 3)
    }

    func testRefreshIntervalIsConfigurable() {
        let volume = Volume([disk(used: 100), disk(used: 200)])
        let metrics = volume.makeMetrics(refreshInterval: 0)

        assertSample(metrics.sample(), used: 100)
        assertSample(metrics.sample(), used: 200)
        XCTAssertEqual(volume.reads, 2)
    }

    // MARK: - Failure fallback

    func testFailureBeforeAnyReadingReturnsNil() {
        let volume = Volume([nil, disk(used: 100)])
        let metrics = volume.makeMetrics()

        assertSample(metrics.sample(), used: nil)
        // Nothing was cached, so the next tick retries immediately.
        assertSample(metrics.sample(), used: 100)
        XCTAssertEqual(volume.reads, 2)
    }

    func testFailedRefreshReturnsTheLastGoodReading() {
        let volume = Volume([disk(used: 100), nil, nil, disk(used: 400)])
        let metrics = volume.makeMetrics()

        assertSample(metrics.sample(), used: 100)
        volume.advance(seconds: 10)
        assertSample(metrics.sample(), used: 100)
        XCTAssertEqual(volume.reads, 2)

        // A failed refresh does not restart the interval: the stale reading is retried on every tick.
        volume.advance(seconds: 1)
        assertSample(metrics.sample(), used: 100)
        XCTAssertEqual(volume.reads, 3)
        assertSample(metrics.sample(), used: 400)
        XCTAssertEqual(volume.reads, 4)
    }

    // MARK: - Capacity → sample

    func testUsedIsTotalMinusAvailable() {
        let sample = DiskMetrics.makeSample(total: 1_000, available: 250)
        XCTAssertEqual(sample?.usedBytes, 750)
        XCTAssertEqual(sample?.totalBytes, 1_000)
    }

    func testAvailableIsClampedToTheVolume() {
        // Purgeable space can make "available for important usage" exceed the capacity.
        XCTAssertEqual(DiskMetrics.makeSample(total: 1_000, available: 5_000)?.usedBytes, 0)
        XCTAssertEqual(DiskMetrics.makeSample(total: 1_000, available: -1)?.usedBytes, 1_000)
    }

    func testEmptyVolumeIsUnreadable() {
        XCTAssertNil(DiskMetrics.makeSample(total: 0, available: 0))
        XCTAssertNil(DiskMetrics.makeSample(total: -1, available: 0))
    }

    func testUnknownVolumeIsUnreadable() {
        XCTAssertNil(DiskMetrics.readCapacity(of: "/nonexistent-\(UUID().uuidString)"))
    }
}
