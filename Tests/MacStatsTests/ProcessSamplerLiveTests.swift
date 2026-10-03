import Darwin
import XCTest
@testable import MacStats

/// The one live-hardware check: the real libproc reader sees this test process.
/// Lenient by design; it also prints the sampler's own cost.
final class ProcessSamplerLiveTests: XCTestCase {

    func testRealReaderSeesThisProcess() throws {
        let reader = LibprocProcessReader()
        let me = getpid()
        XCTAssertTrue(reader.allPIDs().contains(me))
        guard case .success(let usage) = reader.rusage(of: me) else { return XCTFail("cannot read own rusage") }
        XCTAssertGreaterThan(usage.footprintBytes, 0)
        XCTAssertGreaterThan(usage.startTime, 0)
        XCTAssertNotNil(reader.executablePath(of: me))

        let sampler = ProcessSampler(reader: reader)
        XCTAssertNil(sampler.sampleNow())
        Thread.sleep(forTimeInterval: 0.05)
        let report = try XCTUnwrap(sampler.sampleNow())
        let row = try XCTUnwrap(report.processes.first { $0.pids.contains(me) })
        XCTAssertGreaterThan(row.memoryBytes, 0)
        XCTAssertTrue(row.isMeasured)
        XCTAssertFalse(report.top(.memory).isEmpty)
    }

    /// Not an assertion on speed (CI machines vary); records the figure quoted in
    /// `ProcessSampler`'s documentation.
    func testSampleCost() {
        let sampler = ProcessSampler()
        let coldStart = Self.processCPUNanoseconds()
        _ = sampler.sampleNow() // resolves every identity once
        let cold = Double(Self.processCPUNanoseconds() - coldStart) / 1_000_000

        let runs = 20
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = Self.processCPUNanoseconds()
        for _ in 0..<runs { _ = sampler.sampleNow() }
        let cpu = Double(Self.processCPUNanoseconds() - cpuStart) / Double(runs) / 1_000_000
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / Double(runs) / 1_000_000
        let processes = sampler.capture().entries.count
        print(String(format: "ProcessSampler cost: %.2f ms CPU, %.2f ms wall per sample (%d readable processes) "
                     + "= %.3f %% of one core at a 2 s interval; first sample %.2f ms CPU",
                     cpu, wall, processes, cpu / 2_000 * 100, cold))
        XCTAssertLessThan(wall, 500, "a sample should never take a large fraction of the interval")
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func nanoseconds(_ time: timeval) -> UInt64 { UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000 }
        return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
    }
}
