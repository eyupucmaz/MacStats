import AppKit
import SwiftUI

struct StatsView: View {
    @EnvironmentObject var stats: StatsEngine
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab: PopoverTab = .system

    /// Injected by `AppDelegate` so the popover can drive real AppKit windows/menus.
    var onOpenSettings: () -> Void = {}
    var onShowMenu: (NSView) -> Void = { _ in }

    private static let unavailable = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("MacStats section", selection: $selectedTab) {
                Text("System").tag(PopoverTab.system)
                Text("Audio").tag(PopoverTab.audio)
            }
            .pickerStyle(.segmented)

            if selectedTab == .system {
                systemContent
            } else {
                AudioTab()
            }
        }
        .padding(12)
        .frame(width: selectedTab == .system ? 320 : 360)
    }

    private var systemContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if settings.hasVisibleCards {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(cards) { card in
                        StatCard(card: card)
                    }
                }
                .padding(.bottom, 8)
            } else {
                Text("All stats are hidden. Enable some in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("MacStats")
                .font(.headline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Open Settings")

            MenuAnchorButton(action: onShowMenu)
                .frame(width: 16, height: 16)
                .help("More")
                .accessibilityLabel("More actions")
        }
        .padding(.bottom, 4)
    }

    // MARK: - Cards

    private var cards: [StatCardModel] {
        let s = stats.snapshot
        var result: [StatCardModel] = []

        if settings.showCPU {
            result.append(StatCardModel(id: "cpu", title: "CPU",
                                        value: String(format: "%.1f%%", s.cpuUsage),
                                        icon: "cpu", color: .blue,
                                        accessibility: String(format: "CPU %.1f percent", s.cpuUsage)))
        }
        if settings.showGPU {
            result.append(StatCardModel(id: "gpu", title: "GPU",
                                        value: s.isGPUAvailable ? String(format: "%.1f%%", s.gpuUsage) : Self.unavailable,
                                        icon: "display", color: .green,
                                        accessibility: s.isGPUAvailable
                                            ? String(format: "GPU %.1f percent", s.gpuUsage)
                                            : "GPU usage not available"))
        }
        if settings.showMemory {
            let value = formatMemory(s.memoryUsed, s.memoryTotal)
            result.append(StatCardModel(id: "ram", title: "RAM", value: value,
                                        icon: "memorychip", color: .orange,
                                        accessibility: "Memory \(value)"))
        }
        if settings.showBattery {
            let available = s.isBatteryAvailable
            let value = available ? "\(s.batteryLevel)%" : Self.unavailable
            result.append(StatCardModel(id: "battery", title: "Battery", value: value,
                                        icon: batteryIcon(s.batteryState, s.batteryLevel),
                                        color: .yellow,
                                        accessibility: available
                                            ? "Battery \(s.batteryLevel) percent, \(s.batteryState)"
                                            : "Battery not available"))
        }
        if settings.showDisk {
            let available = s.diskTotalBytes > 0
            let percent = available ? Double(s.diskUsedBytes) / Double(s.diskTotalBytes) * 100 : 0
            let free = s.diskTotalBytes - min(s.diskUsedBytes, s.diskTotalBytes)
            let value = available
                ? String(format: "%.0f%% used · %@ free", percent, DiskSize.short(free))
                : Self.unavailable
            result.append(StatCardModel(id: "disk", title: "Disk", value: value,
                                        icon: "internaldrive", color: .purple,
                                        accessibility: available
                                            ? String(format: "Disk %.0f percent full, ", percent)
                                                + "\(DiskSize.spoken(free)) free of \(DiskSize.spoken(s.diskTotalBytes))"
                                            : "Disk usage not available"))
        }
        if settings.showNetwork {
            let value = "↓\(ByteRate.short(s.networkDownBytes))  ↑\(ByteRate.short(s.networkUpBytes))"
            result.append(StatCardModel(id: "network", title: "Network", value: value,
                                        icon: "network", color: .teal,
                                        accessibility: "Network down \(ByteRate.spoken(s.networkDownBytes)), "
                                            + "up \(ByteRate.spoken(s.networkUpBytes))"))
        }
        if settings.showFan {
            let value = s.isFanAvailable ? "\(s.fanRPM) RPM" : "N/A"
            result.append(StatCardModel(id: "fan", title: "Fan", value: value,
                                        icon: "fanblades", color: .red,
                                        accessibility: s.isFanAvailable
                                            ? "Fan \(s.fanRPM) RPM"
                                            : "Fan speed not available"))
        }
        if settings.showTemperature {
            let value = s.isTemperatureAvailable
                ? String(format: "%.1f°C", s.temperature)
                : "N/A"
            result.append(StatCardModel(id: "temp", title: "Temp", value: value,
                                        icon: "thermometer", color: .pink,
                                        accessibility: s.isTemperatureAvailable
                                            ? String(format: "Temperature %.1f degrees Celsius", s.temperature)
                                            : "Temperature not available"))
        }
        return result
    }

    // MARK: - Formatting

    private func formatMemory(_ used: UInt64, _ total: UInt64) -> String {
        guard total > 0 else { return Self.unavailable }
        let usedGB = Double(used) / 1_073_741_824
        let totalGB = Double(total) / 1_073_741_824
        return String(format: "%.1f/%.0f GB", usedGB, totalGB)
    }

    private func batteryIcon(_ state: String, _ level: Int) -> String {
        switch state {
        case "Charging": return "battery.100.bolt"
        case "Full": return "battery.100"
        default:
            switch level {
            case 76...: return "battery.100"
            case 38..<76: return "battery.50"
            case 1..<38: return "battery.25"
            default: return "battery.0"
            }
        }
    }
}

private enum PopoverTab: Hashable {
    case system
    case audio
}

struct StatCardModel: Identifiable {
    let id: String
    let title: String
    let value: String
    let icon: String
    let color: Color
    let accessibility: String
}

/// Adaptive byte-rate formatting: sub-MB values must not collapse to "0".
enum ByteRate {
    /// Compact form for the cards, e.g. "0 B/s", "812 K", "1.2 M".
    static func short(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        switch value {
        case ..<1_024:
            return String(format: "%.0f B", value)
        case ..<1_048_576:
            return String(format: "%.0f K", value / 1_024)
        case ..<1_073_741_824:
            let mb = value / 1_048_576
            return String(format: mb < 10 ? "%.1f M" : "%.0f M", mb)
        default:
            return String(format: "%.1f G", value / 1_073_741_824)
        }
    }

    /// Same as `short` without the space — the menu bar pays for every point of width.
    static func compact(_ bytesPerSecond: Double) -> String {
        short(bytesPerSecond).replacingOccurrences(of: " ", with: "")
    }

    /// Spelled-out form for VoiceOver.
    static func spoken(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        switch value {
        case ..<1_024:
            return String(format: "%.0f bytes per second", value)
        case ..<1_048_576:
            return String(format: "%.0f kilobytes per second", value / 1_024)
        case ..<1_073_741_824:
            return String(format: "%.1f megabytes per second", value / 1_048_576)
        default:
            return String(format: "%.1f gigabytes per second", value / 1_073_741_824)
        }
    }
}

/// Storage sizes in decimal units, matching Finder and About This Mac.
enum DiskSize {
    /// e.g. "820 MB", "9.7 GB", "245 GB", "1.2 TB".
    static func short(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        switch value {
        case ..<1e9:
            return String(format: "%.0f MB", value / 1e6)
        case ..<1e12:
            let gb = value / 1e9
            return String(format: gb < 10 ? "%.1f GB" : "%.0f GB", gb)
        default:
            return String(format: "%.1f TB", value / 1e12)
        }
    }

    /// Spelled-out form for VoiceOver.
    static func spoken(_ bytes: UInt64) -> String {
        short(bytes)
            .replacingOccurrences(of: "MB", with: "megabytes")
            .replacingOccurrences(of: "GB", with: "gigabytes")
            .replacingOccurrences(of: "TB", with: "terabytes")
    }
}

struct StatCard: View {
    let card: StatCardModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: card.icon)
                .foregroundStyle(card.color)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(card.value)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibility)
    }
}

/// A borderless SwiftUI button that hands its backing `NSView` to the action so
/// AppKit can anchor an `NSMenu` to it.
private struct MenuAnchorButton: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More actions")
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func fire(_ sender: NSButton) { action(sender) }
    }
}

#Preview {
    StatsView()
        .environmentObject(StatsEngine.shared)
}
