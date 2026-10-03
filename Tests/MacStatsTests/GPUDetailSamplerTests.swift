import XCTest
@testable import MacStats

/// `GPUDetailSampler` driven by injected readers instead of IOKit and Metal.
final class GPUDetailSamplerTests: XCTestCase {

    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
    }

    private func makeSampler(metalReads: Counter, utilization: Int = 25) -> GPUDetailSampler {
        GPUDetailSampler(
            readEntries: {
                [GPURegistryEntry(registryID: 4, ioClass: "AGXAcceleratorG17G", model: "Apple M5", coreCount: 10,
                                  statistics: ["Device Utilization %": utilization, "Renderer Utilization %": 20])]
            },
            readMetal: {
                metalReads.increment()
                return [GPUMetalDevice(registryID: 4, name: "Apple M5")]
            })
    }

    func testSampleBuildsTheReportAndReadsMetalOncePerVisit() {
        let metalReads = Counter()
        let sampler = makeSampler(metalReads: metalReads)
        let report = sampler.sampleNow()
        XCTAssertEqual(report.gpus.first?.metalName, "Apple M5")
        XCTAssertEqual(report.gpus.first?.statistics?.utilization, 25)
        _ = sampler.sampleNow()
        XCTAssertEqual(metalReads.count, 1)
    }

    func testStartDeliversAtOnceOnMainAndStopEndsDelivery() {
        let metalReads = Counter()
        let sampler = makeSampler(metalReads: metalReads)
        let first = expectation(description: "immediate report")
        let second = expectation(description: "timer report")
        var reports: [GPUDetailReport] = []
        sampler.start(interval: 0.5) { report in
            XCTAssertTrue(Thread.isMainThread)
            reports.append(report)
            if reports.count == 1 { first.fulfill() }
            if reports.count == 2 { second.fulfill() }
        }
        XCTAssertTrue(sampler.isRunning)
        sampler.start(interval: 0.5) { _ in XCTFail("a second start is a no-op") }
        wait(for: [first, second], timeout: 5, enforceOrder: true)
        XCTAssertEqual(reports[0].chartGPU?.statistics?.renderer, 20)

        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
        let countAtStop = reports.count
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(reports.count, countAtStop)
        XCTAssertEqual(metalReads.count, 1)

        _ = sampler.sampleNow()
        XCTAssertEqual(metalReads.count, 2, "a new visit reads the Metal devices again")
    }

    func testIntervalIsClamped() {
        XCTAssertEqual(GPUDetailSampler.period(0.1), 0.5)
        XCTAssertEqual(GPUDetailSampler.period(600), 60)
        XCTAssertEqual(GPUDetailSampler.period(.nan), 1)
        XCTAssertEqual(GPUDetailSampler.period(2), 2)
    }
}
