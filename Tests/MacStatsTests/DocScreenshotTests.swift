import AppKit
import SwiftUI
import XCTest
@testable import MacStats

/// Captures the popover screenshots published in `docs/assets` (epic #20): the card
/// grid and every detail page, in English, in the dark appearance that suits the site.
///
/// Like `PerformanceBudgetTests`, it hosts the real `StatsView` in a real `NSPopover`
/// under the menu bar and runs a real `StatsEngine` at a 1 s refresh. Every chart shows
/// genuine readings: the warm-up only waits while the engine records this Mac. During
/// the warm-up the eight pages are also hosted in an invisible window, so the series a
/// page records only while it is open (disk activity, battery power, GPU renderer and
/// tiler, the pressure and thermal bands, sensor minimum and maximum) fill up as they
/// would for a user who kept the page open.
///
/// Each image is the popover window alone, captured by window ID with
/// `screencapture -x -o -l`; nothing else on screen is recorded. A window capture has no
/// backdrop for the popover's glass material, which then comes out as a flat gray: true
/// to the screen in dark mode, but too dark behind light mode's black text, so light
/// images are opt-in. The popover opens on the sharpest screen (2x on a Retina display),
/// on the side away from the pointer so nothing is hovered; it appears on screen while
/// the test runs, and the test process becomes the active app for the captures.
///
/// Skipped unless `MACSTATS_SCREENSHOTS=1`; it takes about 7 minutes:
///
///     MACSTATS_SCREENSHOTS=1 MACSTATS_SCREENSHOTS_DIR=/tmp/shots \
///         swift test --filter DocScreenshotTests
///
/// - `MACSTATS_SCREENSHOTS_DIR`: output directory (default: a `MacStatsScreenshots`
///   folder in the temporary directory). Files are `grid.png` and
///   `detail-<metric>.png`, with `-light` appended for the light appearance.
/// - `MACSTATS_SCREENSHOTS_WARMUP`: seconds of recording before the first capture
///   (default 330, enough to fill the default 5-minute range).
/// - `MACSTATS_SCREENSHOTS_SETTLE`: seconds each page is open before its capture, so
///   its samplers have delivered (default 6; process lists need two samples 2 s apart).
/// - `MACSTATS_SCREENSHOTS_ONLY`: comma-separated captures, e.g. `grid,cpu`
///   (`grid` or a `MenuBarMetric` raw value: cpu, gpu, ram, disk, network, battery,
///   fan, temp).
/// - `MACSTATS_SCREENSHOTS_APPEARANCES`: `dark` (default), `light` or `dark,light`.
/// - `MACSTATS_SCREENSHOTS_HEIGHTS`: per-page popover height caps in points, e.g.
///   `cpu=420,network=360`. A capped page scrolls exactly as it does past the app's
///   560 pt cap; use it to keep a section out of a published image.
///
/// Before publishing, check every image for personal data: addresses, network and
/// computer names, user names, external volume names, and process names other than
/// well-known apps (see CONTRIBUTING.md).
final class DocScreenshotTests: XCTestCase {

    @MainActor
    func testCaptureDocScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACSTATS_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Set MACSTATS_SCREENSHOTS=1 to capture the documentation screenshots.")
        }
        // Keep the first-run hint out of the images without persisting anything: the
        // registration domain is not written to disk. Must precede `Onboarding.shared`.
        UserDefaults.standard.register(defaults: [Onboarding.Key.hintDismissed: true])
        guard !Onboarding.shared.isHintVisible else {
            throw XCTSkip("The welcome hint is showing; run this test on its own (--filter DocScreenshotTests).")
        }

        let options = ScreenshotOptions(environment: environment)
        try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)

        try L10n.$language.withValue("en") {
            let harness = ScreenshotHarness(options: options)
            defer { harness.tearDown() }
            harness.warmUp()
            for target in options.targets {
                for appearance in options.appearances {
                    try harness.capture(target, appearance: appearance)
                }
            }
        }
        print("screenshots: \(options.directory.path)")
    }
}

/// What to capture and how, from the `MACSTATS_SCREENSHOTS_*` variables.
private struct ScreenshotOptions {
    enum Target: Equatable {
        case grid
        case detail(MenuBarMetric)

        var name: String {
            switch self {
            case .grid: return "grid"
            case .detail(let metric): return metric.rawValue
            }
        }

        var fileStem: String {
            switch self {
            case .grid: return "grid"
            case .detail(let metric): return "detail-\(metric.rawValue)"
            }
        }
    }

    enum Appearance: String {
        case light, dark

        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
        var fileSuffix: String { self == .light ? "-light" : "" }
    }

    let directory: URL
    let warmUp: TimeInterval
    let settle: TimeInterval
    let targets: [Target]
    let appearances: [Appearance]
    let heights: [String: CGFloat]

    init(environment: [String: String]) {
        directory = environment["MACSTATS_SCREENSHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacStatsScreenshots", isDirectory: true)
        warmUp = environment["MACSTATS_SCREENSHOTS_WARMUP"].flatMap(Double.init) ?? 330
        settle = environment["MACSTATS_SCREENSHOTS_SETTLE"].flatMap(Double.init) ?? 6
        let all = [Target.grid] + MenuBarMetric.allCases.map(Target.detail)
        let only = Self.list(environment["MACSTATS_SCREENSHOTS_ONLY"])
        targets = only.isEmpty ? all : all.filter { only.contains($0.name) }
        let appearances = Self.list(environment["MACSTATS_SCREENSHOTS_APPEARANCES"]).compactMap(Appearance.init)
        self.appearances = appearances.isEmpty ? [.dark] : appearances
        var heights: [String: CGFloat] = [:]
        for entry in Self.list(environment["MACSTATS_SCREENSHOTS_HEIGHTS"]) {
            let parts = entry.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let height = Double(parts[1]) { heights[parts[0]] = CGFloat(height) }
        }
        self.heights = heights
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The popover's height cap for the page being captured.
@MainActor
private final class ScreenshotLayout: ObservableObject {
    @Published var maxHeight: CGFloat = StatsView.maxPopoverHeight
}

/// `StatsView` as `AppDelegate` hosts it, under an optional tighter height cap.
private struct ScreenshotRoot: View {
    @ObservedObject var layout: ScreenshotLayout
    let navigation: DetailNavigation

    var body: some View {
        StatsView(navigation: navigation)
            .frame(maxHeight: layout.maxHeight)
    }
}

/// The pages kept open, off screen, while the engine warms up.
@MainActor
private final class RecordingPages: ObservableObject {
    @Published var metrics = MenuBarMetric.allCases
}

private struct RecordingRoot: View {
    @ObservedObject var pages: RecordingPages

    var body: some View {
        VStack(spacing: 0) {
            ForEach(pages.metrics) { metric in
                MetricDetailView(metric: metric)
            }
        }
        .frame(width: StatsView.popoverWidth)
    }
}

/// Owns the engine, the popover and the helper windows for `DocScreenshotTests`.
@MainActor
private final class ScreenshotHarness {
    private let options: ScreenshotOptions
    private let engine = StatsEngine()
    private let navigation = DetailNavigation()
    private let layout = ScreenshotLayout()
    private let recordingPages = RecordingPages()
    private let popover = NSPopover()
    private var anchorWindow: NSWindow?
    private var recordingWindow: NSWindow?

    init(options: ScreenshotOptions) {
        self.options = options
        NSApplication.shared.setActivationPolicy(.accessory)
        engine.setUpdateInterval(1)
        engine.notifiesViews = true

        // `AppDelegate.installPopover`, minus the Audio tab's services. Not transient:
        // a click elsewhere must not close it mid-run.
        popover.behavior = .applicationDefined
        popover.animates = false
        let root = ScreenshotRoot(layout: layout, navigation: navigation)
            .environmentObject(engine)
            .environment(\.locale, Locale(identifier: "en_US"))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
    }

    // MARK: - Warm-up

    /// Records real readings for `options.warmUp` seconds with every page open in an
    /// invisible window, so each page's own series fill too.
    func warmUp() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StatsView.popoverWidth, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: RecordingRoot(pages: recordingPages)
            .environmentObject(engine)
            .environmentObject(DetailNavigation())
            .environment(\.locale, Locale(identifier: "en_US")))
        window.orderFrontRegardless()
        recordingWindow = window

        engine.start()
        print("screenshots: warming up for \(Int(options.warmUp)) s")
        spin(options.warmUp)
    }

    // MARK: - Capturing

    func capture(_ target: ScreenshotOptions.Target, appearance: ScreenshotOptions.Appearance) throws {
        show(appearance: appearance)
        if navigation.route != route(for: target) {
            navigation.back()
            spin(0.5)
            layout.maxHeight = options.heights[target.name] ?? StatsView.maxPopoverHeight
            if case .detail(let metric) = target {
                // The popover's copy of the page takes over its recording: one sampler per page.
                recordingPages.metrics.removeAll { $0 == metric }
                navigation.open(metric)
            }
            spin(options.settle)
        } else {
            // Same page, other appearance: let the material and colors redraw.
            spin(1.5)
        }

        guard let window = popover.contentViewController?.view.window else {
            XCTFail("The popover has no window for \(target.name)")
            return
        }
        let url = options.directory.appendingPathComponent(target.fileStem + appearance.fileSuffix + ".png")
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x no sound, -o no shadow, -l one window by ID.
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "screencapture failed for \(url.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "No image at \(url.path)")
        print("screenshots: \(url.lastPathComponent)")
    }

    private func route(for target: ScreenshotOptions.Target) -> SystemRoute {
        switch target {
        case .grid: return .grid
        case .detail(let metric): return .detail(metric)
        }
    }

    /// Shows the popover in `appearance`, away from the pointer so nothing is hovered.
    private func show(appearance: ScreenshotOptions.Appearance) {
        let named = NSAppearance(named: appearance.name)
        NSApp.appearance = named
        popover.appearance = named
        guard !popover.isShown else { return }

        // The sharpest screen, for 2x images, then the side away from the pointer.
        guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return }
        let visible = screen.visibleFrame
        let pointerOnRight = NSEvent.mouseLocation.x > visible.midX
        // The popover hangs below the anchor, centered on it.
        let anchorX = pointerOnRight ? visible.minX + 260 : visible.maxX - 260
        let anchor = NSWindow(contentRect: NSRect(x: anchorX - 20, y: visible.maxY - 1, width: 40, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.level = .statusBar
        anchor.backgroundColor = .clear
        anchor.orderFrontRegardless()
        anchorWindow = anchor

        // Active, as after a click on the status item: inactive controls draw gray.
        NSApp.activate(ignoringOtherApps: true)
        guard let view = anchor.contentView else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        spin(1)
    }

    func tearDown() {
        popover.close()
        navigation.back()
        engine.stop()
        recordingWindow?.close()
        anchorWindow?.close()
        NSApp.appearance = nil
        spin(0.5)
    }

    /// Runs the main run loop for `seconds` without busy-waiting.
    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        timer.invalidate()
    }
}
