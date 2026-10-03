import AppKit
import Foundation

/// A metric that can be shown directly in the menu bar. Raw values are the
/// persisted identifiers in `AppSettings.menuBarItems`; `allCases` order is the
/// canonical display order.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, disk, network, battery, fan, temp

    var id: String { rawValue }

    /// Three characters keeps the segments visually aligned in the bar.
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .disk: return "DSK"
        case .network: return "NET"
        case .battery: return "BAT"
        case .fan: return "FAN"
        case .temp: return "TMP"
        }
    }

    /// Spelled out for the Settings toggles.
    var settingsTitle: String {
        switch self {
        case .cpu: return "CPU Usage"
        case .gpu: return "GPU"
        case .ram: return "Memory"
        case .disk: return "Disk Usage"
        case .network: return "Network"
        case .battery: return "Battery"
        case .fan: return "Fan Speed"
        case .temp: return "Temperature"
        }
    }
}

/// An immutable copy of the values the menu bar draws, so rendering is a pure
/// function of its input and can be tested without a live `StatsEngine`.
struct MenuBarSnapshot {
    var cpuUsage: Double = 0
    var gpuUsage: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var diskUsedBytes: UInt64 = 0
    var diskTotalBytes: UInt64 = 0
    var networkDownBytes: Double = 0
    var networkUpBytes: Double = 0
    var batteryLevel: Int = 0
    var batteryState: String = "Unknown"
    var fanRPM: Int = 0
    var isFanAvailable: Bool = false
    var temperature: Double = 0
    var isTemperatureAvailable: Bool = false

    init(cpuUsage: Double = 0, gpuUsage: Double = 0,
         memoryUsed: UInt64 = 0, memoryTotal: UInt64 = 0,
         diskUsedBytes: UInt64 = 0, diskTotalBytes: UInt64 = 0,
         networkDownBytes: Double = 0, networkUpBytes: Double = 0,
         batteryLevel: Int = 0, batteryState: String = "Unknown",
         fanRPM: Int = 0, isFanAvailable: Bool = false,
         temperature: Double = 0, isTemperatureAvailable: Bool = false) {
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.networkDownBytes = networkDownBytes
        self.networkUpBytes = networkUpBytes
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.fanRPM = fanRPM
        self.isFanAvailable = isFanAvailable
        self.temperature = temperature
        self.isTemperatureAvailable = isTemperatureAvailable
    }

    /// Call on the main thread — `StatsEngine` publishes there.
    init(engine: StatsEngine) {
        self.init(cpuUsage: engine.cpuUsage,
                  gpuUsage: engine.gpuUsage,
                  memoryUsed: engine.memoryUsed,
                  memoryTotal: engine.memoryTotal,
                  diskUsedBytes: engine.diskUsedBytes,
                  diskTotalBytes: engine.diskTotalBytes,
                  networkDownBytes: engine.networkDownBytes,
                  networkUpBytes: engine.networkUpBytes,
                  batteryLevel: engine.batteryLevel,
                  batteryState: engine.batteryState,
                  fanRPM: engine.fanRPM,
                  isFanAvailable: engine.isFanAvailable,
                  temperature: engine.temperature,
                  isTemperatureAvailable: engine.isTemperatureAvailable)
    }
}

/// Builds the menu bar title. The result is drawn into a *template* image so
/// AppKit inverts it for dark menu bars and for the highlighted (popover open)
/// state — colours set by hand break in at least one of those.
enum MenuBarRenderer {
    private static let unavailable = "—"
    /// Two spaces read as a gap without the noise of a separator glyph.
    private static let separator = "  "

    static func segment(_ metric: MenuBarMetric, _ s: MenuBarSnapshot) -> String {
        "\(metric.label) \(value(metric, s))"
    }

    static func title(_ metrics: [MenuBarMetric], _ s: MenuBarSnapshot) -> String? {
        guard !metrics.isEmpty else { return nil }
        return metrics.map { segment($0, s) }.joined(separator: separator)
    }

    static func image(_ metrics: [MenuBarMetric], _ s: MenuBarSnapshot) -> NSImage? {
        guard let title = title(metrics, s) else { return nil }
        return image(title: title)
    }

    static func image(title: String) -> NSImage {
        // Monospaced digits: without them the item width jitters on every tick
        // and shoves the neighbouring menu bar items sideways.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: title, attributes: attributes)
        let textSize = attributed.size()
        let size = NSSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height))

        let image = NSImage(size: size, flipped: false) { _ in
            attributed.draw(at: NSPoint(x: 2, y: 0))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Values

    private static func value(_ metric: MenuBarMetric, _ s: MenuBarSnapshot) -> String {
        switch metric {
        case .cpu:
            return String(format: "%.0f%%", s.cpuUsage)
        case .gpu:
            return String(format: "%.0f%%", s.gpuUsage)
        case .ram:
            guard s.memoryTotal > 0 else { return unavailable }
            return String(format: "%.1fG", Double(s.memoryUsed) / 1_073_741_824)
        case .disk:
            guard s.diskTotalBytes > 0 else { return unavailable }
            return String(format: "%.0f%%", Double(s.diskUsedBytes) / Double(s.diskTotalBytes) * 100)
        case .network:
            return "↓\(ByteRate.compact(s.networkDownBytes)) ↑\(ByteRate.compact(s.networkUpBytes))"
        case .battery:
            let available = s.batteryLevel > 0 && s.batteryState != "Unknown"
            return available ? "\(s.batteryLevel)%" : unavailable
        case .fan:
            // The RPM unit is dropped here; the popover spells it out.
            return s.isFanAvailable ? "\(s.fanRPM)" : unavailable
        case .temp:
            return s.isTemperatureAvailable ? String(format: "%.0f°C", s.temperature) : unavailable
        }
    }
}
