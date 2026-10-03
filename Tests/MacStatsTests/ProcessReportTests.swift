import AppKit
import Darwin
import XCTest
@testable import MacStats

/// Rate maths, PID lifecycle and ordering of `ProcessReport.make`, fed with hand-built
/// snapshots (CPU time already in nanoseconds).
final class ProcessReportTests: XCTestCase {

    private let second: UInt64 = 1_000_000_000

    private func entry(_ pid: pid_t, start: UInt64 = 1, cpu: UInt64 = 0, memory: UInt64 = 0,
                       read: UInt64 = 0, written: UInt64 = 0, name: String? = nil,
                       identity: ProcessIdentity? = nil) -> ProcessEntry {
        ProcessEntry(pid: pid, startTime: start, cpuNanoseconds: cpu, footprintBytes: memory,
                     diskReadBytes: read, diskWrittenBytes: written,
                     identity: identity ?? ProcessIdentity(name: name ?? "proc\(pid)"))
    }

    private func snapshot(_ entries: [ProcessEntry], skipped: Int = 0, cores: Int = 4) -> ProcessSnapshot {
        ProcessSnapshot(entries: Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { $1 }),
                        skippedCount: skipped, coreCount: cores)
    }

    private func usage(_ report: ProcessReport, pid: pid_t,
                       file: StaticString = #filePath, line: UInt = #line) throws -> ProcessUsage {
        try XCTUnwrap(report.processes.first { $0.pids.contains(pid) }, "no row for pid \(pid)", file: file, line: line)
    }

    // MARK: - CPU

    func testOneCoreFullyBusyIsOneHundredPercent() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, cpu: 5 * second)]),
                                        current: snapshot([entry(10, cpu: 7 * second)], cores: 4),
                                        elapsed: 2)
        let row = try usage(report, pid: 10)
        XCTAssertEqual(row.cpuPercent, 100, accuracy: 1e-9)
        XCTAssertEqual(row.cpuShareOfCapacity, 25, accuracy: 1e-9)
        XCTAssertTrue(row.isMeasured)
    }

    func testMultiThreadedProcessExceedsOneHundredPercent() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, cpu: 0)], cores: 8),
                                        current: snapshot([entry(10, cpu: 6 * second)], cores: 8),
                                        elapsed: 2)
        let row = try usage(report, pid: 10)
        XCTAssertEqual(row.cpuPercent, 300, accuracy: 1e-9)
        XCTAssertEqual(row.cpuShareOfCapacity, 37.5, accuracy: 1e-9)
    }

    func testCPUPercentScalesWithTheElapsedInterval() throws {
        let previous = snapshot([entry(10, cpu: 0)])
        let current = snapshot([entry(10, cpu: second)])
        XCTAssertEqual(try usage(.make(previous: previous, current: current, elapsed: 4), pid: 10).cpuPercent,
                       25, accuracy: 1e-9)
        XCTAssertEqual(try usage(.make(previous: previous, current: current, elapsed: 0.5), pid: 10).cpuPercent,
                       200, accuracy: 1e-9)
    }

    func testCPUPercentIsCappedAtAllCores() throws {
        // Timer jitter must not report more than the machine can do.
        let report = ProcessReport.make(previous: snapshot([entry(10, cpu: 0)], cores: 2),
                                        current: snapshot([entry(10, cpu: 10 * second)], cores: 2),
                                        elapsed: 1)
        XCTAssertEqual(try usage(report, pid: 10).cpuPercent, 200, accuracy: 1e-9)
        XCTAssertEqual(try usage(report, pid: 10).cpuShareOfCapacity, 100, accuracy: 1e-9)
    }

    func testNoElapsedTimeMeasuresNothing() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, cpu: 0)]),
                                        current: snapshot([entry(10, cpu: second)]),
                                        elapsed: 0)
        let row = try usage(report, pid: 10)
        XCTAssertFalse(row.isMeasured)
        XCTAssertEqual(row.cpuPercent, 0)
    }

    // MARK: - Disk I/O and memory

    func testDiskRatesAreBytesPerSecond() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, read: 1_000, written: 500)]),
                                        current: snapshot([entry(10, read: 4_001_000, written: 1_000_500)]),
                                        elapsed: 2)
        let row = try usage(report, pid: 10)
        XCTAssertEqual(row.diskReadBytesPerSecond, 2_000_000, accuracy: 1e-9)
        XCTAssertEqual(row.diskWriteBytesPerSecond, 500_000, accuracy: 1e-9)
        XCTAssertEqual(row.diskBytesPerSecond, 2_500_000, accuracy: 1e-9)
    }

    func testOneDiskCounterGoingBackwardsDoesNotZeroTheOther() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, read: 5_000, written: 100)]),
                                        current: snapshot([entry(10, read: 1_000, written: 300)]),
                                        elapsed: 1)
        let row = try usage(report, pid: 10)
        XCTAssertEqual(row.diskReadBytesPerSecond, 0)
        XCTAssertEqual(row.diskWriteBytesPerSecond, 200)
    }

    func testMemoryIsTheCurrentFootprint() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, memory: 1)]),
                                        current: snapshot([entry(10, memory: 123_456_789)]),
                                        elapsed: 2)
        XCTAssertEqual(try usage(report, pid: 10).memoryBytes, 123_456_789)
    }

    // MARK: - PID lifecycle

    func testNewProcessHasMemoryButNoRate() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, cpu: 0)]),
                                        current: snapshot([entry(10, cpu: second),
                                                           entry(20, cpu: 50 * second, memory: 9_000)]),
                                        elapsed: 1)
        let fresh = try usage(report, pid: 20)
        XCTAssertFalse(fresh.isMeasured)
        XCTAssertEqual(fresh.cpuPercent, 0)
        XCTAssertEqual(fresh.memoryBytes, 9_000)
        XCTAssertEqual(report.top(.cpu).map(\.pid), [10])
        XCTAssertEqual(report.top(.diskIO).map(\.pid), [10])
        XCTAssertEqual(report.top(.memory).map(\.pid), [20, 10])
    }

    func testExitedProcessDropsOut() {
        let report = ProcessReport.make(previous: snapshot([entry(10), entry(11)]),
                                        current: snapshot([entry(10)]),
                                        elapsed: 1)
        XCTAssertEqual(report.processes.flatMap(\.pids), [10])
    }

    func testReusedPIDIsANewProcess() throws {
        // Same PID, later start time, and a CPU counter that happens to be higher:
        // without the start-time check this would read as 3 s of CPU in one second.
        let report = ProcessReport.make(previous: snapshot([entry(10, start: 100, cpu: second, read: 10)]),
                                        current: snapshot([entry(10, start: 200, cpu: 4 * second, read: 900)]),
                                        elapsed: 1)
        let row = try usage(report, pid: 10)
        XCTAssertFalse(row.isMeasured)
        XCTAssertEqual(row.cpuPercent, 0)
        XCTAssertEqual(row.diskReadBytesPerSecond, 0)
    }

    func testCPUCounterGoingBackwardsIsNotMeasured() throws {
        let report = ProcessReport.make(previous: snapshot([entry(10, cpu: 5 * second)]),
                                        current: snapshot([entry(10, cpu: second)]),
                                        elapsed: 1)
        XCTAssertFalse(try usage(report, pid: 10).isMeasured)
    }

    func testSkippedCountComesFromTheCurrentSnapshot() {
        let report = ProcessReport.make(previous: snapshot([], skipped: 3),
                                        current: snapshot([], skipped: 7),
                                        elapsed: 1)
        XCTAssertEqual(report.skippedCount, 7)
    }

    // MARK: - Grouping

    func testHelpersAreSummedUnderTheirApp() throws {
        let bundle = "/Applications/Google Chrome.app"
        let main = ProcessIdentity(name: "Google Chrome", groupBundlePath: bundle, ownBundlePath: bundle,
                                   app: ProcessAppInfo(name: "Google Chrome", icon: NSImage(), isRegular: true))
        let helper = ProcessIdentity(name: "Google Chrome Helper (Renderer)", groupBundlePath: bundle,
                                     ownBundlePath: bundle + "/Contents/Frameworks/Helper (Renderer).app")
        let previous = snapshot([entry(300, cpu: 0, identity: main),
                                 entry(120, cpu: 0, read: 0, identity: helper),
                                 entry(500, cpu: 0, identity: helper)])
        let current = snapshot([entry(300, cpu: second, memory: 100, identity: main),
                                entry(120, cpu: 2 * second, memory: 200, read: 1_000, identity: helper),
                                entry(500, cpu: 0, memory: 300, identity: helper),
                                entry(700, cpu: 9 * second, memory: 400, identity: helper)]) // new
        let report = ProcessReport.make(previous: previous, current: current, elapsed: 1)

        XCTAssertEqual(report.processes.count, 1)
        let row = try usage(report, pid: 300)
        XCTAssertEqual(row.id, bundle)
        XCTAssertEqual(row.name, "Google Chrome")
        XCTAssertEqual(row.pid, 300, "the app's main process leads, not the lowest helper PID")
        XCTAssertEqual(row.pids, [120, 300, 500, 700])
        XCTAssertNotNil(row.icon)
        XCTAssertEqual(row.cpuPercent, 300, accuracy: 1e-9, "the new helper adds no rate")
        XCTAssertEqual(row.memoryBytes, 1_000)
        XCTAssertEqual(row.diskReadBytesPerSecond, 1_000)
    }

    func testHelpersWithoutTheirAppAreNamedAfterTheBundle() throws {
        let bundle = "/Applications/Google Chrome.app"
        let helper = ProcessIdentity(name: "Google Chrome Helper", groupBundlePath: bundle)
        let report = ProcessReport.make(previous: snapshot([]),
                                        current: snapshot([entry(42, identity: helper), entry(41, identity: helper)]),
                                        elapsed: 1)
        let row = try usage(report, pid: 42)
        XCTAssertEqual(row.name, "Google Chrome")
        XCTAssertEqual(row.pid, 41)
        XCTAssertNil(row.icon)
    }

    func testStandaloneProcessesKeepTheirOwnRows() {
        let report = ProcessReport.make(previous: snapshot([]),
                                        current: snapshot([entry(1, name: "launchd"), entry(2, name: "launchd")]),
                                        elapsed: 1)
        XCTAssertEqual(report.processes.map(\.id), ["pid:1", "pid:2"])
        XCTAssertEqual(report.processes.map(\.name), ["launchd", "launchd"])
    }

    // MARK: - Ordering

    func testTopSortsByValueDescending() {
        let report = ProcessReport.make(previous: snapshot([entry(1), entry(2), entry(3)]),
                                        current: snapshot([entry(1, cpu: second / 10),
                                                           entry(2, cpu: second),
                                                           entry(3, cpu: second / 2)]),
                                        elapsed: 1)
        XCTAssertEqual(report.top(.cpu).map(\.pid), [2, 3, 1])
        XCTAssertEqual(report.top(.cpu, count: 2).map(\.pid), [2, 3])
        XCTAssertEqual(report.top(.cpu, count: 0).map(\.pid), [])
    }

    func testTiesAreBrokenByNameThenPID() {
        let names: [pid_t: String] = [5: "beta", 6: "Alpha", 7: "alpha", 8: "beta", 9: "gamma 10", 4: "gamma 9"]
        let previous = snapshot(names.map { entry($0.key, name: $0.value) })
        let current = snapshot(names.map { entry($0.key, cpu: second, memory: 64, name: $0.value) })
        let expected: [pid_t] = [6, 7, 5, 8, 4, 9]

        // Dictionary order differs between runs; the result must not.
        for _ in 0..<20 {
            let report = ProcessReport.make(previous: previous, current: current, elapsed: 1)
            XCTAssertEqual(report.top(.cpu, count: 10).map(\.pid), expected)
            XCTAssertEqual(report.top(.memory, count: 10).map(\.pid), expected)
            XCTAssertEqual(report.top(.diskIO, count: 10).map(\.pid), expected)
        }
    }
}
