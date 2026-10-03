import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest
@testable import MacStats

/// The CPU budget harness for the detail pages (#35, epic #20): ≤ 2 % of one core
/// with a page open at a 1 s refresh, ≤ 0.5 % with the popover closed.
///
/// It rebuilds the app's moving parts in the test process — a real status item
/// showing a live metric, the real `StatsView` in a real `NSPopover` under the menu
/// bar, and a `StatsEngine` sampling the hardware every second over an hour of
/// pre-recorded history — then lets the main run loop idle through each scenario
/// and reports the process's CPU time per wall second. The status item and popover
/// appear on screen while it runs; the popover mirrors `AppDelegate`'s show and
/// close hooks.
///
/// Skipped unless `MACSTATS_PERF=1`; it takes about 7 minutes. Measure release
/// code, as shipped:
///
///     MACSTATS_PERF=1 swift test -c release --filter PerformanceBudgetTests
///
/// - `MACSTATS_PERF_SECONDS`: measuring window per scenario (default 30).
/// - `MACSTATS_PERF_ONLY`: comma-separated scenario names to run, e.g. `closed,cpu`
///   (`floor`, `engine`, `closed`, `grid`, a `MenuBarMetric` raw value, `reclosed`).
///
/// Numbers are % of one core over the window; "main" is the main thread's share.
/// "Minstr" is millions of instructions retired per second, which barely moves with
/// machine load. Run with the Mac otherwise idle: the harness measures only its own
/// process, but on a busy Mac its threads land on efficiency cores and the same work
/// shows up as more CPU time.
final class PerformanceBudgetTests: XCTestCase {

    @MainActor
    func testDetailPageBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACSTATS_PERF"] == "1" else {
            throw XCTSkip("Set MACSTATS_PERF=1 to run the CPU budget harness.")
        }
        let seconds = environment["MACSTATS_PERF_SECONDS"].flatMap(Double.init) ?? 30
        let only = environment["MACSTATS_PERF_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

        let harness = PerformanceHarness()
        var results: [PerformanceHarness.Result] = []
        func run(_ name: String, budget: Double, setUp: () -> Void) {
            setUp()
            guard wanted(name) else { return }
            results.append(harness.measure(name, budget: budget, seconds: seconds))
        }

        // Nothing sampling and no views: what the harness costs on its own.
        run("floor", budget: 0.5) {}
        // The engine and the menu bar item only, as before the popover is created.
        run("engine", budget: 0.5) { harness.startEngine() }
        // The popover exists (as it does for the app's whole life) but was never shown.
        run("closed", budget: 0.5) { harness.installPopover() }
        run("grid", budget: 2) { harness.showPopover() }
        for metric in MenuBarMetric.allCases {
            run(metric.rawValue, budget: 2) { harness.open(metric) }
        }
        // Closed again after visiting every page: nothing a page started may still run.
        run("reclosed", budget: 0.5) { harness.closePopover() }
        harness.tearDown()

        print(PerformanceHarness.table(results, seconds: seconds))
    }
}

/// Owns the status item, popover and engine for `PerformanceBudgetTests`.
@MainActor
private final class PerformanceHarness {
    struct Result {
        let name: String
        let budget: Double
        /// % of one core: the whole process, and the main thread alone.
        let total: Double
        let main: Double
        /// Millions of instructions retired per second by the whole process. Steadier
        /// than CPU time on a busy Mac, where the same work may land on an efficiency
        /// core and take twice as long; use it to compare changes.
        let instructions: Double
    }

    /// Settling time after each change, so the open/close animation, the pages'
    /// first samples and one-off work (icon lookups) stay out of the measurement.
    private static let settleSeconds = 4.0
    private static let menuBarMetrics: [MenuBarMetric] = [.cpu]

    private let engine = StatsEngine()
    private let navigation = DetailNavigation()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var anchorWindow: NSWindow?
    private var renderedTitle: String?
    private var cancellables = Set<AnyCancellable>()
    private let mainThread = mach_thread_self()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        engine.setUpdateInterval(1)
        prefillHistory()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "MacStats")
        statusItem = item
    }

    deinit {
        mach_port_deallocate(mach_task_self_, mainThread)
    }

    // MARK: - Scenarios

    /// Starts sampling and mirrors `AppDelegate.updateStatusItem`.
    func startEngine() {
        engine.$snapshot
            .sink { [weak self] snapshot in self?.updateStatusItem(snapshot) }
            .store(in: &cancellables)
        engine.start()
    }

    /// Same setup as `AppDelegate.installPopover`, minus the Audio tab's services.
    func installPopover() {
        let popover = NSPopover()
        // The app's popover is transient; a click elsewhere must not end the run.
        popover.behavior = .applicationDefined
        let view = StatsView(navigation: navigation).environmentObject(engine)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        self.popover = popover
    }

    /// Anchored to a sliver of a window just under the menu bar where the status
    /// item would be: a status item hidden by a full menu bar (or the notch) has no
    /// frame, and a popover will not show from it.
    func showPopover() {
        guard let popover, let screen = NSScreen.main else { return }
        let anchor = NSWindow(contentRect: NSRect(x: screen.visibleFrame.maxX - 240, y: screen.visibleFrame.maxY - 1,
                                                  width: 40, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.level = .statusBar
        anchor.backgroundColor = .clear
        anchor.orderFrontRegardless()
        anchorWindow = anchor
        guard let view = anchor.contentView else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func open(_ metric: MenuBarMetric) {
        // Back to the grid first, as a user going from page to page would.
        withAnimation(DetailNavigation.animation) { navigation.back() }
        spin(1)
        withAnimation(DetailNavigation.animation) { navigation.open(metric) }
    }

    /// What `AppDelegate.popoverDidClose` does.
    func closePopover() {
        popover?.close()
        navigation.back()
    }

    func tearDown() {
        popover?.close()
        engine.stop()
        cancellables.removeAll()
        statusItem.map(NSStatusBar.system.removeStatusItem)
        statusItem = nil
        anchorWindow?.close()
        spin(0.5)
    }

    // MARK: - Measuring

    func measure(_ name: String, budget: Double, seconds: Double) -> Result {
        spin(Self.settleSeconds)
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let processStart = Self.processCPUSeconds()
        let mainStart = threadCPUSeconds(mainThread)
        let instructionsStart = Self.processInstructions()
        spin(seconds)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000_000
        let result = Result(name: name, budget: budget,
                            total: (Self.processCPUSeconds() - processStart) / wall * 100,
                            main: (threadCPUSeconds(mainThread) - mainStart) / wall * 100,
                            instructions: Double(Self.processInstructions() - instructionsStart) / wall / 1_000_000)
        print("perf " + Self.row(result))
        return result
    }

    static func table(_ results: [Result], seconds: Double) -> String {
        let header = String(format: "CPU budget, %.0f s per scenario; %% of one core, Minstr = 10^6 instructions/s",
                            seconds)
        return (["", header, "scenario   total    main  Minstr  budget"] + results.map(row)).joined(separator: "\n")
    }

    private static func row(_ result: Result) -> String {
        String(format: "%@ %6.2f  %6.2f  %6.1f  %5.1f  %@",
               result.name.padding(toLength: 9, withPad: " ", startingAt: 0),
               result.total, result.main, result.instructions, result.budget,
               result.total <= result.budget ? "ok" : "OVER")
    }

    /// Runs the main run loop for `seconds` without busy-waiting: the timer keeps a
    /// source installed, so each `run(mode:before:)` blocks until something happens.
    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        timer.invalidate()
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func processInstructions() -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_instructions : 0
    }

    private func threadCPUSeconds(_ thread: thread_act_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func seconds(_ time: time_value_t) -> Double { Double(time.seconds) + Double(time.microseconds) / 1_000_000 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    // MARK: - Setup

    /// `AppDelegate.updateStatusItem`: redraw only when the text changes.
    private func updateStatusItem(_ snapshot: StatsSnapshot) {
        guard let button = statusItem?.button,
              let title = MenuBarRenderer.title(Self.menuBarMetrics, snapshot),
              title != renderedTitle else { return }
        renderedTitle = title
        button.image = MenuBarRenderer.image(title: title)
        button.setAccessibilityLabel("MacStats \(title)")
    }

    /// An hour of plausible readings ending now, so every range draws a full chart
    /// as it would after the app has run for a while.
    private func prefillHistory() {
        let now = Date()
        let samples = (0..<3_600).map { index -> CoreMetricSample in
            let wave = (sin(Double(index) / 40) + 1) / 2
            let reading = StatsReading(cpuUsage: 8 + 20 * wave,
                                       cpuUser: 5 + 14 * wave,
                                       cpuSystem: 3 + 6 * wave,
                                       gpuUsage: 4 + 10 * wave,
                                       memoryUsed: UInt64(12 + 2 * wave) << 30,
                                       memoryTotal: 24 << 30,
                                       memoryPressure: 30 + 5 * wave,
                                       disk: DiskSample(usedBytes: 300 << 30, totalBytes: 1_000 << 30),
                                       network: NetworkSample(downBytesPerSecond: 40_000 * wave,
                                                              upBytesPerSecond: 8_000 * wave),
                                       batteryLevel: 80,
                                       batteryState: "Charging",
                                       fanRPM: nil,
                                       temperature: 45 + 8 * wave)
            return CoreMetricSample(reading: reading, date: now.addingTimeInterval(Double(index - 3_600)))
        }
        engine.history.record(samples)
    }
}
