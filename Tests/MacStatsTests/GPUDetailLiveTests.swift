import Darwin
import XCTest
@testable import MacStats

/// The GPU page's one live-hardware check. Lenient by design (a VM or CI runner may have
/// no readable accelerator); it also prints the sampler's own cost, the figure quoted in
/// `GPUDetailSampler`'s documentation.
final class GPUDetailLiveTests: XCTestCase {

    func testLiveReportAndSampleCost() {
        let sampler = GPUDetailSampler()
        let report = sampler.sampleNow() // also loads Metal once
        for gpu in report.gpus {
            XCTAssertTrue(gpu.model != nil || gpu.metalName != nil || gpu.statistics != nil)
            if let value = gpu.statistics?.utilization { XCTAssertTrue((0...100).contains(value)) }
        }
        if GPUMetrics.sample() != nil {
            XCTAssertFalse(report.gpus.isEmpty, "the card reads a GPU, so the page lists one")
        }
        print("GPU report:", report.gpus.map { "\($0.model ?? "?") / \($0.metalName ?? "?") / cores \($0.coreCount ?? 0)" })

        let runs = 50
        let start = Self.processCPUNanoseconds()
        for _ in 0..<runs { _ = sampler.sampleNow() }
        let perSample = Double(Self.processCPUNanoseconds() - start) / Double(runs) / 1_000_000
        print(String(format: "GPUDetailSampler cost: %.3f ms CPU per sample = %.4f %% of one core at 1 s",
                     perSample, perSample / 1_000 * 100))
        XCTAssertLessThan(perSample, 50, "a sample should be far cheaper than its interval")
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func nanoseconds(_ time: timeval) -> UInt64 { UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000 }
        return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
    }
}
