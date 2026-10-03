import XCTest
@testable import MacStats

/// One lenient smoke test against the real Mac: the readers return something sane.
/// Exact values are never asserted.
final class DiskDetailLiveTests: XCTestCase {
    func testReadersWorkOnThisMac() throws {
        let volumes = DiskVolumes.mountedVolumes()
        XCTAssertEqual(volumes.filter(\.isStartup).count, 1, "the startup volume is listed exactly once")
        XCTAssertEqual(volumes.first?.isStartup, true)
        XCTAssertFalse(volumes.contains { $0.path.hasPrefix(DiskVolumes.systemVolumesPrefix) })
        for volume in volumes {
            XCTAssertGreaterThan(volume.totalBytes, 0)
            XCTAssertLessThanOrEqual(volume.freeBytes, volume.totalBytes)
        }

        guard let counters = DiskIOStatistics.readCounters() else {
            throw XCTSkip("this Mac exposes no IOBlockStorageDriver statistics")
        }
        XCTAssertGreaterThan(counters.readBytes, 0, "the startup drive has read something since boot")
    }
}
