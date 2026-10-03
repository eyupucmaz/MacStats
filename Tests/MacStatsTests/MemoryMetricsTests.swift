import XCTest
@testable import MacStats

/// Used/pressure derivation of `MemoryMetrics` from page counts.
final class MemoryMetricsTests: XCTestCase {

    private let page: UInt64 = 16_384
    private let total: UInt64 = 1_000 * 16_384

    func testUsedIsActivePlusWiredPlusCompressed() {
        let s = MemoryMetrics.derive(activePages: 300, wiredPages: 100, compressorPages: 50, pageSize: page, total: total)
        XCTAssertEqual(s.used, 450 * page)
        XCTAssertEqual(s.total, total)
    }

    func testPressureCountsOnlyWiredAndCompressed() {
        let s = MemoryMetrics.derive(activePages: 600, wiredPages: 150, compressorPages: 100, pageSize: page, total: total)
        XCTAssertEqual(s.pressure, 25, accuracy: 1e-9)
    }

    func testUsedAndPressureAreCappedAtTotal() {
        let s = MemoryMetrics.derive(activePages: 900, wiredPages: 700, compressorPages: 600, pageSize: page, total: total)
        XCTAssertEqual(s.used, total)
        XCTAssertEqual(s.pressure, 100)
    }

    func testZeroTotalHasNoPressure() {
        let s = MemoryMetrics.derive(activePages: 1, wiredPages: 1, compressorPages: 1, pageSize: page, total: 0)
        XCTAssertEqual(s.used, 0)
        XCTAssertEqual(s.pressure, 0)
    }

    func testLiveSampleIsConsistent() {
        let s = MemoryMetrics.sample()
        XCTAssertEqual(s.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(s.used, s.total)
        XCTAssertTrue((0 ... 100).contains(s.pressure))
    }
}
