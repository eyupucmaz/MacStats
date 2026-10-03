import Cocoa
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let warmUpSeconds = 2.0

    /// Sampling is suspended while the popover is closed to keep idle CPU near
    /// zero — but only while the menu bar shows a static glyph. Live metrics up
    /// there force continuous sampling; that is the cost of the feature.
    private var pausesPollingWhenHidden: Bool { !AppSettings.shared.showsMetricsInMenuBar }

    private var statusItem: NSStatusItem?
    /// The title currently drawn in the status item; nil while it shows the icon,
    /// which is what `installStatusItem()` starts with.
    private var renderedTitle: String?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var hasTornDown = false
    private var cancellables = Set<AnyCancellable>()
    private let audioDevices = AudioDeviceService()
    private let appMixer = AppMixerService()
    private lazy var statusMenu: NSMenu = makeStatusMenu()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()
        installPopover()

        // Apply the persisted interval before the first tick.
        StatsEngine.shared.setUpdateInterval(AppSettings.shared.updateInterval)
        StatsEngine.shared.start()
        observeStats()

        // Let one warm-up window elapse so deltas have a baseline, then idle down
        // (a no-op when the menu bar is showing live metrics).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmUpSeconds) { [weak self] in
            self?.pausePollingIfHidden()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tearDown()
    }

    /// Idempotent: both `quitApp()` and `applicationWillTerminate` route through here.
    private func tearDown() {
        guard !hasTornDown else { return }
        hasTornDown = true
        appMixer.disable()
        StatsEngine.shared.stop()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "MacStats")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("MacStats")
        }
        statusItem = item
    }

    /// Redraws the status item from the latest sample and keeps the polling
    /// policy in step with the menu bar selection.
    private func observeStats() {
        // The engine publishes on the main thread, so no extra hop. `@Published`
        // emits before the property is set, hence the value is passed along.
        StatsEngine.shared.$snapshot
            .sink { [weak self] snapshot in self?.updateStatusItem(snapshot) }
            .store(in: &cancellables)

        AppSettings.shared.$menuBarItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem(StatsEngine.shared.snapshot)
                self?.applyPollingPolicy()
            }
            .store(in: &cancellables)
    }

    /// Rebuilds the image and accessibility label only when the text changes — at a
    /// 1 s interval most ticks leave a rounded "CPU 4%" untouched.
    private func updateStatusItem(_ snapshot: StatsSnapshot) {
        guard let button = statusItem?.button else { return }
        let title = MenuBarRenderer.title(AppSettings.shared.menuBarMetrics, snapshot)
        guard title != renderedTitle else { return }
        renderedTitle = title

        if let title {
            button.image = MenuBarRenderer.image(title: title)
            button.setAccessibilityLabel("MacStats \(title)")
        } else {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "MacStats")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("MacStats")
        }
    }

    private func applyPollingPolicy() {
        if AppSettings.shared.showsMetricsInMenuBar {
            resumePolling()
        } else {
            pausePollingIfHidden()
        }
    }

    private func installPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        let statsView = StatsView(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onShowMenu: { [weak self] view in self?.showStatusMenu(anchoredTo: view) }
        )
        .environmentObject(StatsEngine.shared)
        .environmentObject(audioDevices)
        .environmentObject(appMixer)

        let controller = NSHostingController(rootView: statsView)
        // Let SwiftUI drive the popover size so hidden cards do not leave a gap.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        self.popover = popover
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showStatusMenu(anchoredTo: sender)
        } else {
            togglePopover()
        }
    }

    @objc func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            resumePolling()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Menu

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About MacStats", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacStats", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Popped up on demand — assigning `statusItem.menu` permanently would swallow left-clicks.
    private func showStatusMenu(anchoredTo view: NSView) {
        popover?.close()
        let origin = NSPoint(x: 0, y: view.bounds.height + 4)
        statusMenu.popUp(positioning: nil, at: origin, in: view)
    }

    /// An accessory app shows no menu bar, but the main menu still supplies ⌘Q / ⌘, to key windows.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacStats", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)

        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Settings window

    @objc func openSettings() {
        popover?.close()

        if settingsWindow == nil {
            let view = SettingsView(onDone: { [weak self] in self?.settingsWindow?.performClose(nil) })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacStats Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.delegate = self
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        popover?.close()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacStats",
            .applicationVersion: SettingsView.versionString,
            .credits: NSAttributedString(
                string: "Menu bar system monitor.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
        ])
    }

    @objc func quitApp() {
        tearDown()
        NSApp.terminate(nil)
    }

    // MARK: - Polling

    /// `setUpdateInterval` is a no-op when the interval is unchanged, so this does not
    /// restart the timer on every popover open.
    private func resumePolling() {
        StatsEngine.shared.setUpdateInterval(AppSettings.shared.updateInterval)
        StatsEngine.shared.start()
    }

    private func pausePollingIfHidden() {
        guard pausesPollingWhenHidden, popover?.isShown != true else { return }
        StatsEngine.shared.stop()
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        pausePollingIfHidden()
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
    }
}
