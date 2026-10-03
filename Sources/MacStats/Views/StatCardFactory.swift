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
        return StatCardModel(id: "cpu", title: "CPU", value: percent + "%",
                             icon: "cpu", color: .blue,
                             accessibility: "CPU \(percent) percent")
    }

    static func gpu(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let percent = MetricFormat.decimal(s.gpuUsage, digits: 1, locale: locale)
        return StatCardModel(id: "gpu", title: "GPU",
                             value: s.isGPUAvailable ? percent + "%" : unavailable,
                             icon: "display", color: .green,
                             accessibility: s.isGPUAvailable ? "GPU \(percent) percent" : "GPU usage not available")
    }

    static func memory(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let available = s.memoryTotal > 0
        return StatCardModel(id: "ram", title: "RAM",
                             value: available ? MemorySize.usedOfTotal(s.memoryUsed, s.memoryTotal, locale: locale) : unavailable,
                             icon: "memorychip", color: .orange,
                             accessibility: available
                                 ? "Memory " + MemorySize.spoken(used: s.memoryUsed, total: s.memoryTotal, locale: locale)
                                 : "Memory not available")
    }

    static func battery(_ s: StatsSnapshot) -> StatCardModel {
        StatCardModel(id: "battery", title: "Battery",
                      value: s.isBatteryAvailable ? "\(s.batteryLevel)%" : unavailable,
                      icon: batteryIcon(state: s.batteryState, level: s.batteryLevel),
                      color: .yellow,
                      accessibility: s.isBatteryAvailable
                          ? "Battery \(s.batteryLevel) percent, \(s.batteryState)"
                          : "Battery not available")
    }

    static func disk(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        guard s.diskTotalBytes > 0 else {
            return StatCardModel(id: "disk", title: "Disk", value: unavailable,
                                 icon: "internaldrive", color: .purple,
                                 accessibility: "Disk usage not available")
        }
        let used = min(s.diskUsedBytes, s.diskTotalBytes)
        let free = s.diskTotalBytes - used
        let percent = MetricFormat.decimal(Double(used) / Double(s.diskTotalBytes) * 100, digits: 0, locale: locale)
        return StatCardModel(id: "disk", title: "Disk",
                             value: "\(percent)% used · \(DiskSize.short(free, locale: locale)) free",
                             icon: "internaldrive", color: .purple,
                             accessibility: "Disk \(percent) percent full, \(DiskSize.spoken(free, locale: locale)) free "
                                 + "of \(DiskSize.spoken(s.diskTotalBytes, locale: locale))")
    }

    static func network(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        StatCardModel(id: "network", title: "Network",
                      value: "↓\(ByteRate.short(s.networkDownBytes, locale: locale))  "
                          + "↑\(ByteRate.short(s.networkUpBytes, locale: locale))",
                      icon: "network", color: .teal,
                      accessibility: "Network down \(ByteRate.spoken(s.networkDownBytes, locale: locale)), "
                          + "up \(ByteRate.spoken(s.networkUpBytes, locale: locale))")
    }

    static func fan(_ s: StatsSnapshot) -> StatCardModel {
        StatCardModel(id: "fan", title: "Fan",
                      value: s.isFanAvailable ? "\(s.fanRPM) RPM" : unavailable,
                      icon: "fanblades", color: .red,
                      accessibility: s.isFanAvailable ? "Fan \(s.fanRPM) RPM" : "Fan speed not available")
    }

    static func temperature(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        let degrees = MetricFormat.decimal(s.temperature, digits: 1, locale: locale)
        return StatCardModel(id: "temp", title: "Temp",
                             value: s.isTemperatureAvailable ? degrees + "°C" : unavailable,
                             icon: "thermometer", color: .pink,
                             accessibility: s.isTemperatureAvailable
                                 ? "Temperature \(degrees) degrees Celsius"
                                 : "Temperature not available")
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
