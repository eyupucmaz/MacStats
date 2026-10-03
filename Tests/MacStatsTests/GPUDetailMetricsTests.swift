import XCTest
@testable import MacStats

/// Parsing of IOAccelerator properties and matching with Metal, from injected dictionaries.
final class GPUDetailMetricsTests: XCTestCase {

    /// Copied from `ioreg -r -c IOAccelerator -l` on an Apple M5.
    private let appleSilicon: [String: Any] = [
        "In use system memory (driver)": 0, "Alloc system memory": 3_294_543_872,
        "Tiler Utilization %": 6, "recoveryCount": 0, "Renderer Utilization %": 21,
        "Device Utilization %": 21, "In use system memory": 910_639_104,
    ]

    func testAppleSiliconStatistics() {
        let stats = GPUStatistics(appleSilicon)
        XCTAssertEqual(stats, GPUStatistics(utilization: 21, renderer: 21, tiler: 6,
                                            memoryInUse: 910_639_104, memoryAllocated: 3_294_543_872))
    }

    func testMissingKeysStayNilAndZeroBytesAreHidden() {
        let stats = GPUStatistics(["GPU Activity(%)": 40, "In use system memory": 0])
        XCTAssertEqual(stats.utilization, 40)
        XCTAssertNil(stats.renderer)
        XCTAssertNil(stats.tiler)
        XCTAssertNil(stats.memoryInUse, "0 means the driver does not track it")
        XCTAssertNil(stats.memoryAllocated)
        XCTAssertNil(GPUStatistics([:]).utilization)
    }

    func testPercentagesAreClamped() {
        let stats = GPUStatistics(["Renderer Utilization %": 140, "Tiler Utilization %": -3, "Device Utilization %": 101])
        XCTAssertEqual(stats.renderer, 100)
        XCTAssertEqual(stats.tiler, 0)
        XCTAssertEqual(stats.utilization, 100)
    }

    func testVideoMemoryTotalIsUsedPlusFree() {
        let stats = GPUStatistics(["vramUsedBytes": 1_000, "vramFreeBytes": 3_000])
        XCTAssertEqual(stats.videoMemoryUsed, 1_000)
        XCTAssertEqual(stats.videoMemoryTotal, 4_000)
        XCTAssertNil(GPUStatistics(["vramUsedBytes": 1_000]).videoMemoryTotal)
    }

    func testUtilizationMatchesTheCardRules() {
        XCTAssertEqual(GPUMetrics.utilization(from: ["Device Utilization %": 33, "GPU Activity(%)": 80]), 33,
                       "the first known key wins, as for the card")
        XCTAssertEqual(GPUMetrics.utilization(from: ["GPU Core Utilization": 5_000_000]), 50,
                       "legacy busy time out of 10 000 000")
        XCTAssertEqual(GPUMetrics.utilization(from: ["GPU Core Utilization": 42]), 42)
        XCTAssertNil(GPUMetrics.utilization(from: ["recoveryCount": 0]))
    }

    func testModelNameFromStringOrBytes() {
        XCTAssertEqual(GPURegistry.modelName(from: "Apple M5"), "Apple M5")
        XCTAssertEqual(GPURegistry.modelName(from: Data("AMD Radeon Pro 5500M\0".utf8)), "AMD Radeon Pro 5500M")
        XCTAssertNil(GPURegistry.modelName(from: Data([0])))
        XCTAssertNil(GPURegistry.modelName(from: "  "))
        XCTAssertNil(GPURegistry.modelName(from: 7))
        XCTAssertEqual(GPURegistry.coreCount(from: NSNumber(value: 10)), 10)
        XCTAssertNil(GPURegistry.coreCount(from: NSNumber(value: 0)))
        XCTAssertNil(GPURegistry.coreCount(from: nil))
    }

    // MARK: - Report

    func testSingleAppleSiliconGPU() {
        let report = GPUDetailReport.make(
            entries: [GPURegistryEntry(registryID: 7, ioClass: "AGXAcceleratorG17G", model: "Apple M5",
                                       coreCount: 10, statistics: appleSilicon)],
            metal: [GPUMetalDevice(registryID: 7, name: "Apple M5")])
        XCTAssertEqual(report.gpus.count, 1)
        let gpu = report.gpus[0]
        XCTAssertEqual(gpu.model, "Apple M5")
        XCTAssertEqual(gpu.coreCount, 10)
        XCTAssertEqual(gpu.metalName, "Apple M5")
        XCTAssertTrue(gpu.isAppleSilicon)
        XCTAssertEqual(report.chartGPU?.id, 7)
    }

    func testIntelPlusDiscreteMatchesMetalByRegistryID() {
        let report = GPUDetailReport.make(
            entries: [
                GPURegistryEntry(registryID: 20, ioClass: "AMDRadeonX6000_AMDNavi14GraphicsAccelerator",
                                 model: "AMD Radeon Pro 5500M",
                                 statistics: ["Device Utilization %": 12, "Renderer Utilization %": 10,
                                              "vramUsedBytes": 512, "vramFreeBytes": 512]),
                GPURegistryEntry(registryID: 10, ioClass: "IntelAccelerator", model: "Intel UHD Graphics 630",
                                 statistics: ["Device Utilization %": 3]),
            ],
            metal: [GPUMetalDevice(registryID: 20, name: "AMD Radeon Pro 5500M"),
                    GPUMetalDevice(registryID: 10, name: "Intel(R) UHD Graphics 630")])
        XCTAssertEqual(report.gpus.map(\.id), [10, 20], "registry order")
        XCTAssertEqual(report.gpus.map(\.metalName), ["Intel(R) UHD Graphics 630", "AMD Radeon Pro 5500M"])
        XCTAssertFalse(report.gpus.contains(where: \.isAppleSilicon))
        XCTAssertEqual(report.gpus.map { $0.statistics?.utilization }, [3, 12])
        XCTAssertEqual(report.chartGPU?.id, 20, "the first GPU that reports renderer or tiler")
    }

    func testEmptyEntriesAreDroppedAndMetalOnlyDevicesKept() {
        let report = GPUDetailReport.make(
            entries: [GPURegistryEntry(registryID: 1), GPURegistryEntry(registryID: 3, model: "Apple M5"),
                      GPURegistryEntry(registryID: 3, model: "Apple M5")],
            metal: [GPUMetalDevice(registryID: 9, name: "Apple M5")])
        XCTAssertEqual(report.gpus, [GPUDevice(id: 3, model: "Apple M5", isAppleSilicon: true),
                                     GPUDevice(id: 9, metalName: "Apple M5", isAppleSilicon: true)])
        XCTAssertNil(report.chartGPU)
        XCTAssertEqual(GPUDetailReport.make(entries: [], metal: []).gpus, [])
    }
}
