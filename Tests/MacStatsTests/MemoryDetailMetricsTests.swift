import Darwin
import XCTest
@testable import MacStats

/// Breakdown, pressure level, swap and paging-rate derivations behind the memory page.
final class MemoryDetailMetricsTests: XCTestCase {

    private let page: UInt64 = 16_384
    private let total: UInt64 = 1_000 * 16_384

    private func counters(free: UInt64 = 0, speculative: UInt64 = 0, wired: UInt64 = 0, compressor: UInt64 = 0,
                          anonymous: UInt64 = 0, external: UInt64 = 0, purgeable: UInt64 = 0) -> VMCounters {
        VMCounters(pageSize: page, freePages: free, speculativePages: speculative, wiredPages: wired,
                   compressorPages: compressor, internalPages: anonymous, externalPages: external,
                   purgeablePages: purgeable)
    }

    // MARK: - Breakdown

    func testBreakdownUsesActivityMonitorDefinitions() throws {
        let c = counters(free: 60, speculative: 10, wired: 200, compressor: 150,
                         anonymous: 300, external: 120, purgeable: 20)
        let b = try XCTUnwrap(MemoryBreakdown.make(c, total: total))
        XCTAssertEqual(b.app, 280 * page, "internal − purgeable")
        XCTAssertEqual(b.wired, 200 * page)
        XCTAssertEqual(b.compressed, 150 * page)
        XCTAssertEqual(b.cached, 140 * page, "external + purgeable")
        XCTAssertEqual(b.free, 50 * page, "free − speculative")
        XCTAssertEqual(b.total, total)
    }

    func testBreakdownNeverUnderflows() throws {
        let b = try XCTUnwrap(MemoryBreakdown.make(counters(free: 5, speculative: 9, anonymous: 3, purgeable: 7),
                                                   total: total))
        XCTAssertEqual(b.app, 0)
        XCTAssertEqual(b.free, 0)
        XCTAssertEqual(b.cached, 7 * page)
    }

    func testBreakdownNeedsATotalAndAPageSize() {
        XCTAssertNil(MemoryBreakdown.make(counters(wired: 1), total: 0))
        var c = counters(wired: 1)
        c.pageSize = 0
        XCTAssertNil(MemoryBreakdown.make(c, total: total))
    }

    func testFractionsScaleToTotalAndNeverOverflow() throws {
        let b = try XCTUnwrap(MemoryBreakdown.make(counters(wired: 250, anonymous: 250), total: total))
        XCTAssertEqual(b.fraction(.wired), 0.25, accuracy: 1e-12)
        XCTAssertEqual(b.fraction(.free), 0)

        // Counts that overshoot physical memory are scaled to their sum instead.
        let over = try XCTUnwrap(MemoryBreakdown.make(counters(wired: 1_500, anonymous: 500), total: total))
        let sum = MemoryBreakdown.Category.allCases.reduce(0) { $0 + over.fraction($1) }
        XCTAssertEqual(sum, 1, accuracy: 1e-12)
        XCTAssertEqual(over.fraction(.wired), 0.75, accuracy: 1e-12)
    }

    // MARK: - Pressure level

    func testKernelPressureLevels() {
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 4), .critical)
        XCTAssertNil(MemoryPressureLevel(kernelValue: 0))
        XCTAssertNil(MemoryPressureLevel(kernelValue: 3))
    }

    func testSeverityRoundTrips() {
        for level in MemoryPressureLevel.allCases {
            XCTAssertEqual(MemoryPressureLevel(severity: level.severity), level)
        }
        XCTAssertEqual(MemoryPressureLevel.allCases.map(\.severity), [0, 1, 2])
        XCTAssertNil(MemoryPressureLevel(severity: 5))
    }

    // MARK: - Swap

    func testSwapUsageFromSysctlStruct() {
        var raw = xsw_usage()
        raw.xsu_total = 2_147_483_648
        raw.xsu_used = 536_870_912
        raw.xsu_avail = 1_610_612_736
        XCTAssertEqual(SwapUsage(raw), SwapUsage(used: 536_870_912, total: 2_147_483_648))
    }

    // MARK: - Paging rates

    func testRatesArePagesTimesPageSizePerSecond() throws {
        var before = counters()
        before.pageIns = 100
        before.pageOuts = 10
        before.swapIns = 5
        before.swapOuts = 7
        before.compressions = 1_000
        before.decompressions = 900
        var after = before
        after.pageIns += 20
        after.pageOuts += 2
        after.swapOuts += 4
        after.compressions += 50
        after.decompressions += 10

        let r = try XCTUnwrap(PagingRates.make(previous: before, current: after, elapsed: 2))
        XCTAssertEqual(r.pageIns, Double(10 * page))
        XCTAssertEqual(r.pageOuts, Double(page))
        XCTAssertEqual(r.swapIns, 0, "no change is a measured zero, not a missing value")
        XCTAssertEqual(r.swapOuts, Double(2 * page))
        XCTAssertEqual(r.compressions, Double(25 * page))
        XCTAssertEqual(r.decompressions, Double(5 * page))
    }

    func testCounterGoingBackwardsHidesOnlyThatRate() throws {
        var before = counters()
        before.pageIns = 100
        before.swapOuts = 50
        var after = before
        after.pageIns = 40
        after.swapOuts = 60
        let r = try XCTUnwrap(PagingRates.make(previous: before, current: after, elapsed: 1))
        XCTAssertNil(r.pageIns)
        XCTAssertEqual(r.swapOuts, Double(10 * page))
    }

    func testNoRatesWithoutElapsedTimeOrWithChangedPageSize() {
        let c = counters()
        XCTAssertNil(PagingRates.make(previous: c, current: c, elapsed: 0))
        XCTAssertNil(PagingRates.make(previous: c, current: c, elapsed: .nan))
        var other = c
        other.pageSize = 4_096
        XCTAssertNil(PagingRates.make(previous: c, current: other, elapsed: 1))
    }

    func testCountersFromVMStatistics() {
        var stats = vm_statistics64_data_t()
        stats.free_count = 10
        stats.speculative_count = 2
        stats.wire_count = 30
        stats.compressor_page_count = 40
        stats.internal_page_count = 50
        stats.external_page_count = 60
        stats.purgeable_count = 3
        stats.pageins = 7
        stats.pageouts = 8
        stats.swapins = 9
        stats.swapouts = 11
        stats.compressions = 12
        stats.decompressions = 13
        let c = VMCounters(stats, pageSize: page)
        XCTAssertEqual(c, VMCounters(pageSize: page, freePages: 10, speculativePages: 2, wiredPages: 30,
                                     compressorPages: 40, internalPages: 50, externalPages: 60,
                                     purgeablePages: 3, pageIns: 7, pageOuts: 8, swapIns: 9, swapOuts: 11,
                                     compressions: 12, decompressions: 13))
    }
}
