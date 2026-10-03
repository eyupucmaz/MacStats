import SwiftUI

struct StatCardModel: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let icon: String
    let color: Color
    let accessibility: String
}

/// Builds the popover cards from a snapshot. Every value and VoiceOver string is made
/// here rather than in the SwiftUI view, so the wording and units are unit-tested.
/// Units follow one rule per kind: RAM in binary "GB" (`MemorySize`), storage in decimal
/// like Finder (`DiskSize`), throughput in decimal per second (`ByteRate`).
/// Text comes from `L10n`; `locale` only decides how the numbers are written.
enum StatCardFactory {
    private static let unavailable = MetricFormat.unavailable

    /// The visible cards, in display order.
    static func cards(_ s: StatsSnapshot, settings: AppSettings,
                      locale: Locale = .autoupdatingCurrent) -> [StatCardModel] {
        var result: [StatCardModel] = []
        if settings.showCPU { result.append(cpu(s, locale: locale)) }
        if settings.showGPU { result.append(gpu(s, locale: locale)) }
        if settings.showMemory { result.append(memory(s, locale: locale)) }
        if settings.showBattery { result.append(battery(s)) }
        if settings.showDisk { result.append(disk(s, locale: locale)) }
        if settings.showNetwork { result.append(network(s, locale: locale)) }
        if settings.showFan { result.append(fan(s)) }
        if settings.showTemperature { result.append(temperature(s, locale: locale)) }
        return result
    }

    static func cpu(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let percent = MetricFormat.decimal(s.cpuUsage, digits: 1, locale: locale)
        return StatCardModel(id: "cpu", title: L10n.string("CPU"), value: MetricFormat.percent(percent),
                             icon: "cpu", color: .blue,
                             accessibility: L10n.string("CPU \(percent) percent"))
    }

    static func gpu(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let percent = MetricFormat.decimal(s.gpuUsage, digits: 1, locale: locale)
        return StatCardModel(id: "gpu", title: L10n.string("GPU"),
                             value: s.isGPUAvailable ? MetricFormat.percent(percent) : unavailable,
                             icon: "display", color: .green,
                             accessibility: s.isGPUAvailable
                                 ? L10n.string("GPU \(percent) percent")
                                 : L10n.string("GPU usage not available"))
    }

    static func memory(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let available = s.memoryTotal > 0
        return StatCardModel(id: "ram", title: L10n.string("RAM"),
                             value: available ? MemorySize.usedOfTotal(s.memoryUsed, s.memoryTotal, locale: locale) : unavailable,
                             icon: "memorychip", color: .orange,
                             accessibility: available
                                 ? L10n.string("Memory \(MemorySize.spoken(used: s.memoryUsed, total: s.memoryTotal, locale: locale))")
                                 : L10n.string("Memory not available"))
    }

    static func battery(_ s: StatsSnapshot) -> StatCardModel {
        StatCardModel(id: "battery", title: L10n.string("Battery"),
                      value: s.isBatteryAvailable ? MetricFormat.percent("\(s.batteryLevel)") : unavailable,
                      icon: batteryIcon(state: s.batteryState, level: s.batteryLevel),
                      color: .yellow,
                      accessibility: s.isBatteryAvailable
                          ? L10n.string("Battery \(String(s.batteryLevel)) percent, \(batteryStateText(s.batteryState))")
                          : L10n.string("Battery not available"))
    }

    /// `batteryState` is an identifier shared with `BatteryMetrics` (and matched
    /// in `batteryIcon`), so it is translated only where it is spoken.
    static func batteryStateText(_ state: String) -> String {
        switch state {
        case "Charging": return L10n.string("Charging")
        case "Full": return L10n.string("Full")
        case "Discharging": return L10n.string("Discharging")
        case "AC Power": return L10n.string("AC Power")
        default: return L10n.string("Unknown")
        }
    }

    static func disk(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        guard s.diskTotalBytes > 0 else {
            return StatCardModel(id: "disk", title: L10n.string("Disk"), value: unavailable,
                                 icon: "internaldrive", color: .purple,
                                 accessibility: L10n.string("Disk usage not available"))
        }
        let used = min(s.diskUsedBytes, s.diskTotalBytes)
        let free = s.diskTotalBytes - used
        let percent = MetricFormat.decimal(Double(used) / Double(s.diskTotalBytes) * 100, digits: 0, locale: locale)
        let freeText = DiskSize.short(free, locale: locale)
        let spokenFree = DiskSize.spoken(free, locale: locale)
        let spokenTotal = DiskSize.spoken(s.diskTotalBytes, locale: locale)
        return StatCardModel(id: "disk", title: L10n.string("Disk"),
                             value: L10n.string("\(percent)% used · \(freeText) free"),
                             icon: "internaldrive", color: .purple,
                             accessibility: L10n.string("Disk \(percent) percent full, \(spokenFree) free of \(spokenTotal)"))
    }

    static func network(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let down = ByteRate.spoken(s.networkDownBytes, locale: locale)
        let up = ByteRate.spoken(s.networkUpBytes, locale: locale)
        return StatCardModel(id: "network", title: L10n.string("Network"),
                             value: "↓\(ByteRate.short(s.networkDownBytes, locale: locale))  "
                                 + "↑\(ByteRate.short(s.networkUpBytes, locale: locale))",
                             icon: "network", color: .teal,
                             accessibility: L10n.string("Network down \(down), up \(up)"))
    }

    static func fan(_ s: StatsSnapshot) -> StatCardModel {
        StatCardModel(id: "fan", title: L10n.string("Fan"),
                      value: s.isFanAvailable ? L10n.string("\(String(s.fanRPM)) RPM") : unavailable,
                      icon: "fanblades", color: .red,
                      accessibility: s.isFanAvailable
                          ? L10n.string("Fan \(String(s.fanRPM)) RPM")
                          : L10n.string("Fan speed not available"))
    }

    static func temperature(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let degrees = MetricFormat.decimal(s.temperature, digits: 1, locale: locale)
        return StatCardModel(id: "temp", title: L10n.string("Temp"),
                             value: s.isTemperatureAvailable ? degrees + "°C" : unavailable,
                             icon: "thermometer", color: .pink,
                             accessibility: s.isTemperatureAvailable
                                 ? L10n.string("Temperature \(degrees) degrees Celsius")
                                 : L10n.string("Temperature not available"))
    }

    static func batteryIcon(state: String, level: Int) -> String {
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
