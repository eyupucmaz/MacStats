import Darwin
import XCTest
@testable import MacStats

/// `ProcessSampler` driven by a fake libproc reader and a fake clock: timebase conversion,
/// skipped counting, identity caching and the start/stop lifecycle.
final class ProcessSamplerTests: XCTestCase {

    private final class FakeReader: ProcessReading {
        var timebase = ProcessTimebase(numer: 1, denom: 1)
        var coreCount = 4
        var results: [pid_t: ProcessRusageResult] = [:]
        var paths: [pid_t: String] = [:]
        var names: [pid_t: String] = [:]
        var apps: [pid_t: ProcessAppInfo] = [:]
        private(set) var pathLookups: [pid_t] = []
        private(set) var appLookups: [pid_t] = []

        func allPIDs() -> [pid_t] { results.keys.sorted() }
        func rusage(of pid: pid_t) -> ProcessRusageResult { results[pid] ?? .exited }
        func executablePath(of pid: pid_t) -> String? {
            pathLookups.append(pid)
            return paths[pid]
        }
        func shortName(of pid: pid_t) -> String? { names[pid] }
        func runningApp(pid: pid_t) -> ProcessAppInfo? {
            appLookups.append(pid)
            return apps[pid]
        }

        func set(_ pid: pid_t, start: UInt64 = 1, cpuTicks: UInt64 = 0, memory: UInt64 = 0,
                 read: UInt64 = 0, written: UInt64 = 0) {
            results[pid] = .success(ProcessRusage(pid: pid, startTime: start, cpuTicks: cpuTicks,
                                                  footprintBytes: memory, diskReadBytes: read,
                                                  diskWrittenBytes: written))
        }
    }

    private final class Clock {
        var nanoseconds: UInt64 = 1_000_000_000
        func advance(seconds: Double) { nanoseconds += UInt64(seconds * 1_000_000_000) }
    }

    private var reader: FakeReader!
    private var clock: Clock!
    private var sampler: ProcessSampler!

    override func setUp() {
        super.setUp()
        reader = FakeReader()
        clock = Clock()
        let clock = self.clock!
        sampler = ProcessSampler(reader: reader, now: { clock.nanoseconds })
    }

    override func tearDown() {
        sampler.stop()
        sampler = nil
        super.tearDown()
    }

    // MARK: - Timebase

    func testTimebaseConversion() {
        let appleSilicon = ProcessTimebase(numer: 125, denom: 3)
        XCTAssertEqual(appleSilicon.nanoseconds(fromTicks: 24_000_000), 1_000_000_000)
        XCTAssertEqual(appleSilicon.nanoseconds(fromTicks: 3), 125)
        XCTAssertEqual(ProcessTimebase(numer: 1, denom: 1).nanoseconds(fromTicks: 12_345), 12_345)
        // Exact past 64 bits of intermediate product, saturating only when the result overflows.
        XCTAssertEqual(appleSilicon.nanoseconds(fromTicks: 3 * (UInt64.max / 125)), 125 * (UInt64.max / 125))
        XCTAssertEqual(appleSilicon.nanoseconds(fromTicks: .max), .max)
    }

    func testCPUTicksAreConvertedWithTheReadersTimebase() throws {
        reader.timebase = ProcessTimebase(numer: 125, denom: 3)
        reader.coreCount = 10
        reader.set(10, cpuTicks: 0)
        XCTAssertNil(sampler.sampleNow(), "no baseline yet")

        // 2 s of CPU at 24 MHz ticks over a 2 s wall interval: one core.
        reader.set(10, cpuTicks: 48_000_000)
        clock.advance(seconds: 2)
        let row = try XCTUnwrap(sampler.sampleNow()?.processes.first)
        XCTAssertEqual(row.cpuPercent, 100, accuracy: 1e-9)
        XCTAssertEqual(row.cpuShareOfCapacity, 10, accuracy: 1e-9)
    }

    func testDiskRatesUseTheClock() throws {
        reader.set(10, read: 0, written: 0)
        _ = sampler.sampleNow()
        reader.set(10, read: 3_000, written: 600)
        clock.advance(seconds: 3)
        let row = try XCTUnwrap(sampler.sampleNow()?.processes.first)
        XCTAssertEqual(row.diskReadBytesPerSecond, 1_000, accuracy: 1e-9)
        XCTAssertEqual(row.diskWriteBytesPerSecond, 200, accuracy: 1e-9)
    }

    func testNoTimeElapsedGivesNoReport() {
        reader.set(10)
        _ = sampler.sampleNow()
        XCTAssertNil(sampler.sampleNow())
    }

    // MARK: - Skipped and exited processes

    func testDeniedProcessesAreSkippedAndCountedExitedOnesAreNot() throws {
        reader.set(10, memory: 5)
        reader.results[1] = .denied
        reader.results[2] = .denied
        reader.results[3] = .exited
        let snapshot = sampler.capture()
        XCTAssertEqual(snapshot.skippedCount, 2)
        XCTAssertEqual(Array(snapshot.entries.keys), [10])
        XCTAssertFalse(reader.pathLookups.contains(1), "denied processes are not inspected further")
    }

    // MARK: - Identities

    func testIdentityIsResolvedOncePerProcessLifetime() {
        let chrome = "/Applications/Google Chrome.app"
        reader.paths[10] = chrome + "/Contents/MacOS/Google Chrome"
        reader.paths[11] = chrome + "/Contents/Frameworks/Helpers/Google Chrome Helper"
        reader.apps[10] = ProcessAppInfo(name: "Google Chrome", icon: nil, isRegular: true)
        reader.set(10)
        reader.set(11)

        _ = sampler.capture()
        _ = sampler.capture()
        XCTAssertEqual(reader.pathLookups.sorted(), [10, 11])
        XCTAssertEqual(reader.appLookups, [10], "only an app's main executable is looked up")

        // PID 11 is reused by an unrelated process.
        reader.paths[11] = "/usr/bin/yes"
        reader.set(11, start: 2)
        let snapshot = sampler.capture()
        XCTAssertEqual(reader.pathLookups.sorted(), [10, 11, 11])
        XCTAssertEqual(snapshot.entries[11]?.identity.name, "yes")
        XCTAssertNil(snapshot.entries[11]?.identity.groupBundlePath)
    }

    func testGroupedReportFromTheReader() throws {
        let chrome = "/Applications/Google Chrome.app"
        reader.paths[10] = chrome + "/Contents/MacOS/Google Chrome"
        reader.paths[11] = chrome + "/Contents/Frameworks/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
        reader.apps[10] = ProcessAppInfo(name: "Google Chrome", icon: nil, isRegular: true)
        reader.apps[11] = ProcessAppInfo(name: "Google Chrome Helper (GPU)", icon: nil, isRegular: false)
        reader.names[12] = "kernel_task"
        reader.set(10, cpuTicks: 0, memory: 100)
        reader.set(11, cpuTicks: 0, memory: 50)
        reader.set(12, cpuTicks: 0, memory: 1)
        _ = sampler.sampleNow()

        reader.set(10, cpuTicks: 500_000_000, memory: 100)
        reader.set(11, cpuTicks: 1_500_000_000, memory: 50)
        reader.set(12, cpuTicks: 100_000_000, memory: 1)
        clock.advance(seconds: 1)
        let report = try XCTUnwrap(sampler.sampleNow())

        XCTAssertEqual(report.top(.cpu).map(\.name), ["Google Chrome", "kernel_task"])
        let chromeRow = try XCTUnwrap(report.top(.cpu).first)
        XCTAssertEqual(chromeRow.pids, [10, 11])
        XCTAssertEqual(chromeRow.pid, 10)
        XCTAssertEqual(chromeRow.cpuPercent, 200, accuracy: 1e-9)
        XCTAssertEqual(chromeRow.memoryBytes, 150)
    }

    // MARK: - Lifecycle

    func testStopDropsTheBaseline() {
        reader.set(10)
        _ = sampler.sampleNow()
        sampler.stop()
        clock.advance(seconds: 1)
        XCTAssertNil(sampler.sampleNow(), "a stopped sampler must not report the gap as one interval")
    }

    func testStartDeliversOnMainAfterOneIntervalAndStopEndsDelivery() {
        // Real clock: the timer fires on wall time.
        let sampler = ProcessSampler(reader: reader)
        reader.set(10, cpuTicks: 0)
        let delivered = expectation(description: "report")
        delivered.assertForOverFulfill = false
        var reports = 0
        sampler.start(interval: 0.5) { report in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(report.processes.map(\.pid), [10])
            reports += 1
            delivered.fulfill()
        }
        XCTAssertTrue(sampler.isRunning)
        sampler.start(interval: 0.5) { _ in XCTFail("a second start is a no-op") }
        wait(for: [delivered], timeout: 5)

        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
        let countAtStop = reports
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(reports, countAtStop)
    }
}
