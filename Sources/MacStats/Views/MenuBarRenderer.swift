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

    /// Spelled out for the Settings table: the component plus what is measured,
    /// so every row reads the same way.
    var settingsTitle: String {
        switch self {
        case .cpu: return "CPU Usage"
        case .gpu: return "GPU Usage"
        case .ram: return "Memory Usage"
        case .disk: return "Disk Usage"
        case .network: return "Network Traffic"
        case .battery: return "Battery Level"
        case .fan: return "Fan Speed"
        case .temp: return "Temperature"
        }
    }
}

/// Builds the menu bar title as a pure function of a `StatsSnapshot`, so it can be
/// tested without a live `StatsEngine`. The result is drawn into a *template* image
/// so AppKit inverts it for dark menu bars and for the highlighted (popover open)
/// state — colours set by hand break in at least one of those.
enum MenuBarRenderer {
    private static let unavailable = MetricFormat.unavailable
    /// Two spaces read as a gap without the noise of a separator glyph.
    private static let separator = "  "

    static func segment(_ metric: MenuBarMetric, _ s: StatsSnapshot,
                        locale: Locale = .autoupdatingCurrent) -> String {
        "\(metric.label) \(value(metric, s, locale))"
    }

    static func title(_ metrics: [MenuBarMetric], _ s: StatsSnapshot,
                      locale: Locale = .autoupdatingCurrent) -> String? {
        guard !metrics.isEmpty else { return nil }
        return metrics.map { segment($0, s, locale: locale) }.joined(separator: separator)
    }

    static func image(_ metrics: [MenuBarMetric], _ s: StatsSnapshot) -> NSImage? {
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

    /// Same units as the cards, compacted: whole numbers and single-letter units,
    /// since the menu bar pays for every point of width.
    private static func value(_ metric: MenuBarMetric, _ s: StatsSnapshot, _ locale: Locale) -> String {
        switch metric {
        case .cpu:
            return MetricFormat.percent(s.cpuUsage, digits: 0, locale: locale)
        case .gpu:
            return s.isGPUAvailable ? MetricFormat.percent(s.gpuUsage, digits: 0, locale: locale) : unavailable
        case .ram:
            guard s.memoryTotal > 0 else { return unavailable }
            return MemorySize.compact(s.memoryUsed, locale: locale)
        case .disk:
            guard s.diskTotalBytes > 0 else { return unavailable }
            let used = min(s.diskUsedBytes, s.diskTotalBytes)
            return MetricFormat.percent(Double(used) / Double(s.diskTotalBytes) * 100, digits: 0, locale: locale)
        case .network:
            return "↓\(ByteRate.compact(s.networkDownBytes, locale: locale)) "
                + "↑\(ByteRate.compact(s.networkUpBytes, locale: locale))"
        case .battery:
            return s.isBatteryAvailable ? "\(s.batteryLevel)%" : unavailable
        case .fan:
            // The RPM unit is dropped here; the popover spells it out.
            return s.isFanAvailable ? "\(s.fanRPM)" : unavailable
        case .temp:
            guard s.isTemperatureAvailable else { return unavailable }
            return MetricFormat.decimal(s.temperature, digits: 0, locale: locale) + "°C"
        }
    }
}
