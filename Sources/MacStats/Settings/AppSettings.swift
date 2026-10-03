import Combine
import Foundation

/// Where a metric can appear: as a card in the popover, or in the menu bar title.
enum MetricPlacement: CaseIterable {
    case card, menuBar
}

/// Single source of truth for user preferences, backed by `UserDefaults`.
/// Both `StatsView` and `SettingsView` observe this object — no scattered `@AppStorage`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let showGPU = "showGPU"
        static let showDisk = "showDisk"
        static let showNetwork = "showNetwork"
        static let showBattery = "showBattery"
        static let showFan = "showFan"
        static let showTemperature = "showTemperature"
        static let updateInterval = "updateInterval"
        static let launchAtLogin = "launchAtLogin"
        static let menuBarItems = "menuBarItems"
    }

    static let defaultValues: [String: Any] = [
        Key.showCPU: true,
        Key.showMemory: true,
        Key.showGPU: true,
        Key.showDisk: true,
        Key.showNetwork: true,
        Key.showBattery: true,
        Key.showFan: true,
        Key.showTemperature: true,
        Key.updateInterval: 1.0,
        Key.launchAtLogin: false,
        Key.menuBarItems: [MenuBarMetric.cpu.rawValue]
    ]

    /// Interval choices offered in Settings, in seconds.
    static let intervalChoices: [Double] = [1.0, 2.0, 5.0, 30.0]

    private let defaults: UserDefaults
    /// Guards the revert inside `applyLaunchAtLogin()` from re-entering `didSet`.
    private var isRevertingLaunchAtLogin = false

    @Published var showCPU: Bool { didSet { persist(showCPU, Key.showCPU) } }
    @Published var showMemory: Bool { didSet { persist(showMemory, Key.showMemory) } }
    @Published var showGPU: Bool { didSet { persist(showGPU, Key.showGPU) } }
    @Published var showDisk: Bool { didSet { persist(showDisk, Key.showDisk) } }
    @Published var showNetwork: Bool { didSet { persist(showNetwork, Key.showNetwork) } }
    @Published var showBattery: Bool { didSet { persist(showBattery, Key.showBattery) } }
    @Published var showFan: Bool { didSet { persist(showFan, Key.showFan) } }
    @Published var showTemperature: Bool { didSet { persist(showTemperature, Key.showTemperature) } }

    /// Identifiers of the metrics drawn in the menu bar. Deliberately separate
    /// from the `show*` card flags: wanting every card in the popover but only
    /// CPU in the menu bar is the normal case.
    @Published var menuBarItems: [String] { didSet { persist(menuBarItems, Key.menuBarItems) } }

    @Published var updateInterval: Double {
        didSet {
            guard updateInterval != oldValue else { return }
            persist(updateInterval, Key.updateInterval)
            StatsEngine.shared.setUpdateInterval(updateInterval)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    /// Non-nil when the last Launch-at-Login change failed; surfaced in Settings.
    @Published private(set) var launchAtLoginError: String?

    /// False when MacStats is not running from an `.app` bundle.
    var isLaunchAtLoginSupported: Bool { LaunchAtLogin.isSupported }
    var launchAtLoginStatusDescription: String { LaunchAtLogin.statusDescription }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.defaultValues)

        showCPU = defaults.bool(forKey: Key.showCPU)
        showMemory = defaults.bool(forKey: Key.showMemory)
        showGPU = defaults.bool(forKey: Key.showGPU)
        showDisk = defaults.bool(forKey: Key.showDisk)
        showNetwork = defaults.bool(forKey: Key.showNetwork)
        showBattery = defaults.bool(forKey: Key.showBattery)
        showFan = defaults.bool(forKey: Key.showFan)
        showTemperature = defaults.bool(forKey: Key.showTemperature)
        menuBarItems = defaults.stringArray(forKey: Key.menuBarItems) ?? [MenuBarMetric.cpu.rawValue]
        // Snap to an offered choice so the segmented picker always has a selection.
        let storedInterval = defaults.double(forKey: Key.updateInterval)
        updateInterval = Self.intervalChoices.contains(storedInterval) ? storedInterval : 1.0
        // Trust launchd, not the stored flag: the user can remove the login item elsewhere.
        launchAtLogin = LaunchAtLogin.isSupported
            ? LaunchAtLogin.isEnabled
            : defaults.bool(forKey: Key.launchAtLogin)
    }

    /// Selected metrics in canonical order; unknown stored identifiers drop out.
    var menuBarMetrics: [MenuBarMetric] {
        MenuBarMetric.allCases.filter { menuBarItems.contains($0.rawValue) }
    }

    /// When false the status item falls back to the app glyph.
    var showsMetricsInMenuBar: Bool { !menuBarMetrics.isEmpty }

    func setMenuBarMetric(_ metric: MenuBarMetric, enabled: Bool) {
        let isSelected = menuBarItems.contains(metric.rawValue)
        guard isSelected != enabled else { return }
        if enabled {
            menuBarItems.append(metric.rawValue)
        } else {
            menuBarItems.removeAll { $0 == metric.rawValue }
        }
    }

    /// The persisted popover-card flag for each metric. Settings shows the card
    /// and menu bar choices side by side, so both are addressed by `MenuBarMetric`.
    static func cardKeyPath(for metric: MenuBarMetric) -> ReferenceWritableKeyPath<AppSettings, Bool> {
        switch metric {
        case .cpu: return \.showCPU
        case .gpu: return \.showGPU
        case .ram: return \.showMemory
        case .disk: return \.showDisk
        case .network: return \.showNetwork
        case .battery: return \.showBattery
        case .fan: return \.showFan
        case .temp: return \.showTemperature
        }
    }

    func isShown(_ metric: MenuBarMetric, in placement: MetricPlacement) -> Bool {
        switch placement {
        case .card: return self[keyPath: Self.cardKeyPath(for: metric)]
        case .menuBar: return menuBarItems.contains(metric.rawValue)
        }
    }

    func setShown(_ metric: MenuBarMetric, in placement: MetricPlacement, _ shown: Bool) {
        switch placement {
        case .card: self[keyPath: Self.cardKeyPath(for: metric)] = shown
        case .menuBar: setMenuBarMetric(metric, enabled: shown)
        }
    }

    /// True when at least one card is enabled — used to keep the popover from collapsing.
    var hasVisibleCards: Bool {
        showCPU || showMemory || showGPU || showDisk || showNetwork || showBattery || showFan || showTemperature
    }

    /// Re-reads the live launchd state (cheap; called when Settings appears).
    func refreshLaunchAtLoginState() {
        guard LaunchAtLogin.isSupported else { return }
        let enabled = LaunchAtLogin.isEnabled
        guard enabled != launchAtLogin else { return }
        isRevertingLaunchAtLogin = true
        launchAtLogin = enabled
        isRevertingLaunchAtLogin = false
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try LaunchAtLogin.register()
            } else {
                try LaunchAtLogin.unregister()
            }
            launchAtLoginError = nil
            persist(launchAtLogin, Key.launchAtLogin)
        } catch {
            launchAtLoginError = error.localizedDescription
            // Snap the toggle back to reality instead of pretending the change stuck.
            isRevertingLaunchAtLogin = true
            launchAtLogin = LaunchAtLogin.isEnabled
            isRevertingLaunchAtLogin = false
            persist(launchAtLogin, Key.launchAtLogin)
        }
    }

    private func persist(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
