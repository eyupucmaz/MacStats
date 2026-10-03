import Darwin
import XCTest
@testable import MacStats

/// The one live check of the Network page's readers: lenient (a CI Mac may have no
/// Wi-Fi or no link at all), and it prints the sampler's cost.
final class NetworkDetailLiveTests: XCTestCase {

    func testLiveSampleAndCost() {
        let sampler = NetworkDetailSampler(ledger: NetworkTrafficLedger())
        _ = sampler.sampleNow() // creates the CoreWLAN client once

        let runs = 20
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = Self.processCPUNanoseconds()
        var report = NetworkDetailReport()
        for _ in 0..<runs { report = sampler.sampleNow() }
        let cpu = Double(Self.processCPUNanoseconds() - cpuStart) / Double(runs) / 1_000_000
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / Double(runs) / 1_000_000
        print(String(format: "NetworkDetailSampler cost: %.2f ms CPU, %.2f ms wall per sample "
                     + "= %.3f %% of one core at a 2 s interval; %d interfaces, Wi-Fi %@",
                     cpu, wall, cpu / 2_000 * 100, report.interfaces.count,
                     report.wifi == nil ? "not associated" : "associated"))

        XCTAssertNotNil(report.sinceBoot, "the 64-bit interface counters are always readable")
        for interface in report.interfaces {
            XCTAssertTrue(NetworkMetrics.countsTraffic(of: interface.name), interface.name)
            XCTAssertNotNil(interface.downRate, "two readings give every listed interface a rate")
        }
        if let wifi = report.wifi {
            XCTAssertLessThan(wifi.rssi ?? 0, 0)
        }
        XCTAssertLessThan(wall, 500, "a sample should never take a large fraction of the interval")
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func nanoseconds(_ time: timeval) -> UInt64 { UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000 }
        return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
    }
}
