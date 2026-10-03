import XCTest
@testable import MacStats

/// Formatting, the pressure band and the rows of the memory detail page.
final class MemoryDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let turkish = Locale(identifier: "tr_TR")
    private let gib: UInt64 = 1_073_741_824

    // MARK: - Sizes

    func testBinarySizesLabelledLikeActivityMonitor() {
        XCTAssertEqual(MemoryDetailFormat.bytes(0, locale: english), "0 B")
        XCTAssertEqual(MemoryDetailFormat.bytes(16_384, locale: english), "16 KB")
        XCTAssertEqual(MemoryDetailFormat.bytes(812 * 1_048_576, locale: english), "812 MB")
        XCTAssertEqual(MemoryDetailFormat.bytes(UInt64(2.63 * Double(gib)), locale: english), "2.6 GB")
        XCTAssertEqual(MemoryDetailFormat.bytes(128 * gib, locale: english), "128 GB")
        XCTAssertEqual(MemoryDetailFormat.bytes(UInt64(2.63 * Double(gib)), locale: turkish), "2,6 GB")
    }

    func testUnitStepsUpWhenRoundingReachesOneThousand() {
        XCTAssertEqual(MemoryDetailFormat.bytes(UInt64(999.6 * 1_048_576), locale: english), "1.0 GB")
        XCTAssertEqual(MemoryDetailFormat.bytes(999 * 1_048_576, locale: english), "999 MB")
    }

    func testInstalledMemoryIsWholeGigabytes() {
        XCTAssertEqual(MemoryDetailFormat.installed(16 * gib, locale: english), "16 GB")
        XCTAssertEqual(MemoryDetailFormat.spokenInstalled(16 * gib, locale: english), "16 gigabytes")
    }

    // MARK: - Pressure band

    private let end = Date(timeIntervalSince1970: 10_000)

    private func point(_ secondsBeforeEnd: TimeInterval, _ level: MemoryPressureLevel?) -> MetricPoint {
        MetricPoint(date: end.addingTimeInterval(-secondsBeforeEnd), value: level?.severity)
    }

    func testBandMergesRunsAndStopsAtGaps() {
        let points = [
            point(60, .normal), point(58, .normal), point(56, .warning),
            point(54, nil),                                  // gap marker: page was closed
            point(20, .warning), point(18, .critical),
        ]
        let band = MemoryPressureBand(points: points, range: .oneMinute, end: end, interval: 2)
        XCTAssertEqual(band.domain, end.addingTimeInterval(-60)...end)
        XCTAssertEqual(band.segments.map(\.level), [.normal, .warning, .warning, .critical])
        XCTAssertEqual(band.segments[0].start, end.addingTimeInterval(-60))
        XCTAssertEqual(band.segments[0].end, end.addingTimeInterval(-56))
        XCTAssertEqual(band.segments[1].end, end.addingTimeInterval(-54), "a reading ends at the gap marker")
        XCTAssertEqual(band.segments[3].end, end.addingTimeInterval(-16), "the newest reading holds one interval")
    }

    func testBandIsClippedToTheRange() {
        let band = MemoryPressureBand(points: [point(61, .warning), point(1, .normal)],
                                      range: .oneMinute, end: end, interval: 2)
        XCTAssertEqual(band.segments.first?.start, end.addingTimeInterval(-60))
        XCTAssertEqual(band.segments.last?.end, end)
    }

    func testBandSummary() {
        let band = MemoryPressureBand(points: [point(8, .normal), point(2, .warning)],
                                      range: .oneMinute, end: end, interval: 2)
        // 6 s normal, 2 s warning.
        XCTAssertEqual(band.shares.map(\.level), [.warning, .normal])
        XCTAssertEqual(band.summary(locale: english), "Warning 25%, Normal 75%")
        XCTAssertEqual(MemoryPressureBand(points: [], range: .oneMinute, end: end, interval: 2).summary(locale: english),
                       "No readings yet")
    }

    // MARK: - Rows

    func testPagingRowsHideUnmeasuredRates() {
        let rates = PagingRates(pageIns: 1_200_000, pageOuts: nil, swapIns: 0, swapOuts: nil,
                                compressions: 3_000, decompressions: nil)
        let rows = MemoryDetailRow.paging(swap: SwapUsage(used: gib / 2, total: 2 * gib), rates: rates, locale: english)
        XCTAssertEqual(rows.map(\.label), ["Swap used", "Page-ins", "Swap-ins", "Compressions"])
        XCTAssertEqual(rows[0].value, "512 MB / 2.0 GB")
        XCTAssertEqual(rows[0].spoken, "512 megabytes, total 2.0 gigabytes")
        XCTAssertEqual(rows[1].value, "1.2 MB/s")
        XCTAssertEqual(rows[2].value, "0 B/s")
    }

    func testNoSwapFileReadsNotInUse() {
        let rows = MemoryDetailRow.paging(swap: SwapUsage(used: 0, total: 0), rates: nil, locale: english)
        XCTAssertEqual(rows.map(\.value), ["Not in use"])
        XCTAssertTrue(MemoryDetailRow.paging(swap: nil, rates: nil).isEmpty)
    }

    func testAboutRowsHideUnknownValues() {
        XCTAssertTrue(MemoryDetailRow.about(nil).isEmpty)
        let rows = MemoryDetailRow.about(MemoryDetail(pageSize: 16_384, physicalMemory: 16 * gib), locale: english)
        XCTAssertEqual(rows.map(\.label), ["Physical memory", "Page size"])
        XCTAssertEqual(rows.map(\.value), ["16 GB", "16 KB"])
    }

    func testRowsRenderInTurkish() {
        L10n.$language.withValue("tr") {
            let rows = MemoryDetailRow.paging(swap: SwapUsage(used: gib, total: 2 * gib),
                                              rates: PagingRates(pageIns: 2_500), locale: turkish)
            XCTAssertEqual(rows.map(\.label), ["Kullanılan takas", "Sayfa girişleri"])
            XCTAssertEqual(rows[0].spoken, "1,0 gigabayt, toplam 2,0 gigabayt")
            XCTAssertEqual(MemoryPressureLevel.warning.title, "Uyarı")
            XCTAssertEqual(MemoryBreakdown.Category.cached.title, "Önbellekteki dosyalar")
        }
    }
}
