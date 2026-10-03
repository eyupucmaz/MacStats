import AppKit
import Combine
import XCTest
@testable import MacStats

/// The pieces behind the detail pages' CPU budget (#35): engine notifications gated on
/// the popover, page updates riding on the engine's ticks, the chart's plot mapping,
/// top-process selection and the Core Animation bars. The budget itself is measured by
/// `PerformanceBudgetTests`.
@MainActor
final class DetailBudgetTests: XCTestCase {

    private final class FixedSampler: StatsSampler {
        var cpu = 10.0
        func primeBaselines() {}
        func resetBaselines() {}
        func read() -> StatsReading {
            cpu += 1
            return StatsReading(cpuUsage: cpu, memoryUsed: 1, memoryTotal: 2)
        }
    }

    private func flushMain() {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
    }

    // MARK: - Engine

    func testViewsAreNotNotifiedWhileTheGateIsOff() {
        let engine = StatsEngine(sampler: FixedSampler())
        var willChange = 0
        var snapshots = 0
        let viewSubscription = engine.objectWillChange.sink { willChange += 1 }
        let itemSubscription = engine.$snapshot.dropFirst().sink { _ in snapshots += 1 }

        engine.sampleNow()
        flushMain()
        XCTAssertEqual(willChange, 1)

        engine.notifiesViews = false
        engine.sampleNow()
        engine.sampleNow()
        flushMain()
        XCTAssertEqual(willChange, 1, "a closed popover must not re-render")
        XCTAssertEqual(snapshots, 2, "the status item keeps its updates")

        engine.notifiesViews = true
        XCTAssertEqual(willChange, 2, "reopening catches the views up once")
        engine.notifiesViews = true
        XCTAssertEqual(willChange, 2)

        viewSubscription.cancel()
        itemSubscription.cancel()
    }

    func testCoalescedUpdatesRunWithTheNextTick() {
        let engine = StatsEngine(sampler: FixedSampler())
        var order: [String] = []
        let subscription = engine.objectWillChange.sink { order.append("tick") }

        engine.coalesce { order.append("page 1") }
        engine.coalesce { order.append("page 2") }
        flushMain()
        XCTAssertEqual(order, [], "updates wait for a tick")

        engine.sampleNow()
        flushMain()
        XCTAssertEqual(order, ["page 1", "page 2", "tick"], "applied in the tick's own run loop turn")
        subscription.cancel()
    }

    func testCoalescedUpdateRunsOnItsOwnWhenNoTickComes() {
        let engine = StatsEngine(sampler: FixedSampler())
        let ran = expectation(description: "update ran without a tick")
        let start = Date()
        engine.coalesce { ran.fulfill() }
        wait(for: [ran], timeout: StatsEngine.maximumUpdateDelay + 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), StatsEngine.maximumUpdateDelay - 0.05)
    }

    // MARK: - Chart plot mapping

    func testPlotMappingIsLinearBetweenTheScaleEnds() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let mapping = ChartPlotMapping(dates: start...start.addingTimeInterval(100), values: 0...50,
                                       startX: 40, endX: 240, lowY: 110, highY: 10)
        XCTAssertEqual(mapping.point(date: start, value: 0), CGPoint(x: 40, y: 110))
        XCTAssertEqual(mapping.point(date: start.addingTimeInterval(100), value: 50), CGPoint(x: 240, y: 10))
        XCTAssertEqual(mapping.point(date: start.addingTimeInterval(25), value: 10), CGPoint(x: 90, y: 90))
    }

    func testPlotMappingSurvivesAnEmptyDomain() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let mapping = ChartPlotMapping(dates: start...start, values: 5...5,
                                       startX: 40, endX: 240, lowY: 110, highY: 10)
        XCTAssertEqual(mapping.point(date: start, value: 5), CGPoint(x: 40, y: 110))
    }

    // MARK: - Top processes

    func testTopSelectionMatchesAFullSort() {
        var generator = SystemRandomNumberGenerator()
        let names = ["Safari", "safari", "Mail", "kernel_task", "WindowServer", "app 2", "app 10"]
        for _ in 0..<20 {
            let rows = (0..<200).map { index -> ProcessUsage in
                // Few distinct values, so most comparisons fall through to the name and PID.
                let value = Double(Int.random(in: 0...3, using: &generator))
                return ProcessUsage(id: "pid:\(index)", pid: pid_t(index), pids: [pid_t(index)],
                                    name: names.randomElement(using: &generator)!, icon: nil,
                                    cpuPercent: value, cpuShareOfCapacity: value / 4,
                                    memoryBytes: UInt64(value) * 1_024,
                                    diskReadBytesPerSecond: value, diskWriteBytesPerSecond: 0,
                                    isMeasured: Bool.random(using: &generator))
            }
            let report = ProcessReport(processes: rows, skippedCount: 0, coreCount: 4)
            for metric in [ProcessMetric.cpu, .memory, .diskIO] {
                let candidates = metric == .memory ? rows : rows.filter(\.isMeasured)
                let sorted = candidates.sorted { lhs, rhs in
                    let left = lhs.value(of: metric), right = rhs.value(of: metric)
                    if left != right { return left > right }
                    switch lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric]) {
                    case .orderedAscending: return true
                    case .orderedDescending: return false
                    case .orderedSame: return lhs.name != rhs.name ? lhs.name < rhs.name : lhs.pid < rhs.pid
                    }
                }
                XCTAssertEqual(report.top(metric, count: 5).map(\.pid), sorted.prefix(5).map(\.pid))
            }
        }
    }

    func testDiskListLeavesOutIdleProcesses() {
        func row(_ pid: pid_t, read: Double, measured: Bool = true) -> ProcessUsage {
            ProcessUsage(id: "pid:\(pid)", pid: pid, pids: [pid], name: "p\(pid)", icon: nil,
                         cpuPercent: 0, cpuShareOfCapacity: 0, memoryBytes: 0,
                         diskReadBytesPerSecond: read, diskWriteBytesPerSecond: 0, isMeasured: measured)
        }
        let report = ProcessReport(processes: [row(1, read: 0), row(2, read: 50), row(3, read: 10),
                                               row(4, read: 99, measured: false), row(5, read: 70)],
                                   skippedCount: 0, coreCount: 4)
        XCTAssertEqual(DiskDetailPresentation.topProcesses(report).map(\.pid), [5, 2, 3])
        XCTAssertEqual(DiskDetailPresentation.topProcesses(report, count: 2).map(\.pid), [5, 2])
    }

    // MARK: - Animated bar

    func testBarStacksItsFillsFromTheStart() throws {
        let view = AnimatedBarView(frame: NSRect(x: 0, y: 0, width: 10, height: 100))
        let red = NSColor.red, blue = NSColor.blue
        view.configure(AnimatedBar(direction: .up, segments: [.init(fraction: 0.3, color: red),
                                                              .init(fraction: 0.2, color: blue)]),
                       animated: false)
        view.layout()
        let fills = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(fills.map(\.frame), [CGRect(x: 0, y: 0, width: 10, height: 30),
                                            CGRect(x: 0, y: 30, width: 10, height: 20)])

        // Fewer segments (no reading) empties the bar instead of leaving old fills behind.
        view.configure(AnimatedBar(direction: .up, segments: []), animated: false)
        XCTAssertEqual(fills.map(\.frame.height), [0, 0])
    }

    func testForwardBarRoundsItsFill() throws {
        let view = AnimatedBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 6))
        view.configure(AnimatedBar(direction: .forward, segments: [.init(fraction: 1.5, color: .green)],
                                   roundsFills: true),
                       animated: false)
        let fill = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertEqual(fill.frame, CGRect(x: 0, y: 0, width: 200, height: 6), "fractions are clamped")
        XCTAssertEqual(fill.cornerRadius, 3)
    }
}
