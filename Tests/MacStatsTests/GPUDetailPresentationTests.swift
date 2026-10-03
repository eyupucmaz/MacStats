import XCTest
@testable import MacStats

/// Rows, wording and history recording of the GPU detail page.
final class GPUDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let turkish = Locale(identifier: "tr_TR")
    private let gib: UInt64 = 1_073_741_824

    private func gpu(_ statistics: GPUStatistics? = nil, model: String? = "Apple M5", cores: Int? = 10,
                     metal: String? = "Apple M5") -> GPUDevice {
        GPUDevice(id: 1, model: model, coreCount: cores, metalName: metal, isAppleSilicon: true, statistics: statistics)
    }

    // MARK: - Memory

    func testMemoryRowsShowOnlyWhatTheDriverReports() {
        XCTAssertEqual(GPUDetailPresentation.memoryRows(nil, locale: english), [])
        XCTAssertEqual(GPUDetailPresentation.memoryRows(GPUStatistics(utilization: 20), locale: english), [])

        let rows = GPUDetailPresentation.memoryRows(
            GPUStatistics(memoryInUse: 868 * 1_048_576, memoryAllocated: UInt64(3.1 * Double(gib))), locale: english)
        XCTAssertEqual(rows.map(\.label), ["In use", "Allocated"])
        XCTAssertEqual(rows.map(\.value), ["868 MB", "3.1 GB"])
        XCTAssertEqual(rows[1].spoken, "3.1 gigabytes")
    }

    func testVideoMemoryWithAndWithoutTotal() {
        let both = GPUDetailPresentation.memoryRows(
            GPUStatistics(videoMemoryUsed: gib, videoMemoryTotal: 4 * gib), locale: english)
        XCTAssertEqual(both, [GPUDetailRow(label: "Video memory", value: "1.0 GB / 4.0 GB",
                                           spoken: "1.0 gigabytes, total 4.0 gigabytes")])
        let usedOnly = GPUDetailPresentation.memoryRows(GPUStatistics(videoMemoryUsed: gib), locale: english)
        XCTAssertEqual(usedOnly.map(\.value), ["1.0 GB"])
    }

    func testUnifiedMemoryNoteOnlyForAppleSilicon() {
        XCTAssertTrue(GPUDetailPresentation.showsUnifiedMemoryNote(GPUDetailReport(gpus: [gpu()])))
        let intel = GPUDevice(id: 2, model: "Intel UHD Graphics 630")
        XCTAssertFalse(GPUDetailPresentation.showsUnifiedMemoryNote(GPUDetailReport(gpus: [intel])))
        XCTAssertFalse(GPUDetailPresentation.showsUnifiedMemoryNote(GPUDetailReport()))
    }

    // MARK: - About

    func testAboutRowsHideWhatIsUnknown() {
        XCTAssertEqual(GPUDetailPresentation.aboutRows(gpu(), includeModel: true).map(\.label),
                       ["Model", "GPU cores", "Metal device"])
        XCTAssertEqual(GPUDetailPresentation.aboutRows(gpu(), includeModel: true).map(\.value),
                       ["Apple M5", "10", "Apple M5"])
        XCTAssertEqual(GPUDetailPresentation.aboutRows(gpu(), includeModel: false).map(\.label),
                       ["GPU cores", "Metal device"])
        XCTAssertEqual(GPUDetailPresentation.aboutRows(gpu(model: nil, cores: nil, metal: nil), includeModel: true), [])
    }

    func testNameFallsBackToMetalThenGPU() {
        XCTAssertEqual(GPUDetailPresentation.name(of: gpu(model: nil, metal: "AMD Radeon Pro 5500M")), "AMD Radeon Pro 5500M")
        XCTAssertEqual(GPUDetailPresentation.name(of: gpu(model: nil, metal: nil)), "GPU")
    }

    func testPerGPUUtilization() {
        let busy = gpu(GPUStatistics(utilization: 12.5))
        XCTAssertEqual(GPUDetailPresentation.utilization(of: busy, locale: english).text, "12.5%")
        XCTAssertEqual(GPUDetailPresentation.spokenGPU(busy, locale: english), "Apple M5, 12.5 percent")
        XCTAssertEqual(GPUDetailPresentation.utilization(of: gpu(), locale: english).text, MetricFormat.unavailable)
        XCTAssertEqual(GPUDetailPresentation.spokenGPU(gpu(), locale: english), "Apple M5, Unavailable")
    }

    func testTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(GPUDetailPresentation.chartLabels[GPUDetailSeries.renderer], "Oluşturucu")
            XCTAssertEqual(GPUDetailPresentation.aboutRows(gpu(), includeModel: false).first?.label, "GPU çekirdekleri")
            let rows = GPUDetailPresentation.memoryRows(GPUStatistics(memoryAllocated: UInt64(3.1 * Double(gib))),
                                                        locale: turkish)
            XCTAssertEqual(rows.first?.label, "Ayrılmış")
            XCTAssertEqual(rows.first?.value, "3,1 GB")
        }
    }

    // MARK: - History

    func testRecordsRendererAndTilerOnlyWhenReported() {
        let history = MetricHistory()
        let date = Date(timeIntervalSince1970: 1_000)
        GPUDetailSeries.record(GPUDetailReport(gpus: [gpu(GPUStatistics(utilization: 30))]),
                               in: history, interval: 1, at: date)
        XCTAssertFalse(history.contains(GPUDetailSeries.renderer), "no slot spent on a driver without the split")
        XCTAssertFalse(history.contains(GPUDetailSeries.tiler))

        GPUDetailSeries.record(GPUDetailReport(gpus: [gpu(GPUStatistics(utilization: 30, renderer: 28, tiler: 4))]),
                               in: history, interval: 1, at: date)
        let renderer = history.series(GPUDetailSeries.renderer, range: .oneMinute, now: date)
        let tiler = history.series(GPUDetailSeries.tiler, range: .oneMinute, now: date)
        XCTAssertEqual(renderer?.points.compactMap(\.value), [28])
        XCTAssertEqual(tiler?.points.compactMap(\.value), [4])
        XCTAssertEqual(renderer?.unit, .percent)
    }
}
