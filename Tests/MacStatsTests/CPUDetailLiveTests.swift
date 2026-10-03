import Darwin
import XCTest
@testable import MacStats

/// The CPU page's one live-hardware check. Lenient by design; it also prints the
/// detail sampler's own cost, the figure quoted in `CPUDetailSampler`'s documentation.
final class CPUDetailLiveTests: XCTestCase {

    func testRealSourcesAndSampleCost() {
        let info = CPUInfo.read()
        XCTAssertGreaterThan(info.logicalCores, 0)
        XCTAssertEqual(info.groups.reduce(0) { $0 + $1.cores.count }, info.logicalCores)
        XCTAssertLessThan(info.bootTime ?? .distantPast, Date())
        XCTAssertNotNil(ProcessArguments.firstArgument(of: getpid()), "argv[0] of this test process")

        let sampler = CPUDetailSampler()
        _ = sampler.sampleNow() // baseline
        Thread.sleep(forTimeInterval: 0.05)
        let reading = sampler.sampleNow()
        if let cores = reading.cores {
            XCTAssertEqual(cores.count, info.logicalCores)
            for core in cores.compactMap({ $0 }) { XCTAssertTrue((0...100).contains(core.total)) }
        }
        XCTAssertNotNil(reading.loadAverage)

        let runs = 50
        let start = Self.processCPUNanoseconds()
        for _ in 0..<runs { _ = sampler.sampleNow() }
        let perSample = Double(Self.processCPUNanoseconds() - start) / Double(runs) / 1_000_000
        print(String(format: "CPUDetailSampler cost: %.3f ms CPU per sample = %.4f %% of one core at 1 s",
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
