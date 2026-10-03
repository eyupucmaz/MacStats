import Foundation
import IOKit
import IOKit.ps

struct BatterySample {
    let level: Int          // 0...100, 0 when there is no battery
    let state: String       // "Charging" / "Full" / "Discharging" / "AC Power" / "Unknown"
    let isCharging: Bool
    let health: Int         // percent of design capacity, 0 when unknown
    let cycleCount: Int     // 0 when unknown
}

/// Battery from IOPSCopyPowerSourcesInfo/IOPSGetPowerSourceDescription, plus health and
/// cycle count from the AppleSmartBattery IOService. Limitation: desktops expose no
/// internal battery, which reads as level 0 / "AC Power"; AppleSmartBattery keys are
/// private and absent on some models, so health and cycles then stay 0, and the health
/// ratio is a few points below the smoothed figure System Information displays.
final class BatteryMetrics {

    private var cachedHealth = 0
    private var cachedCycles = 0
    private var healthSampledAt: UInt64 = 0
    private let healthInterval: UInt64 = 60_000_000_000  // AppleSmartBattery changes slowly; poll it once a minute

    func sample() -> BatterySample {
        refreshHealthIfNeeded()

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatterySample(level: 0, state: "Unknown", isCharging: false, health: 0, cycleCount: 0)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let reading = Self.reading(from: description) else { continue }
            return BatterySample(level: reading.level,
                                 state: reading.state,
                                 isCharging: reading.isCharging,
                                 health: cachedHealth,
                                 cycleCount: cachedCycles)
        }

        // No internal battery: desktop on wall power.
        return BatterySample(level: 0, state: "AC Power", isCharging: false, health: 0, cycleCount: 0)
    }

    private func refreshHealthIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        if healthSampledAt != 0 && now &- healthSampledAt < healthInterval { return }
        healthSampledAt = now

        guard let matching = IOServiceMatching("AppleSmartBattery") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            cachedHealth = 0
            cachedCycles = 0
            return
        }
        defer { IOObjectRelease(service) }

        cachedCycles = intProperty(service, "CycleCount") ?? 0
        let design = intProperty(service, "DesignCapacity") ?? 0
        // NominalChargeCapacity/AppleRawMaxCapacity are mAh; "MaxCapacity" is a percentage on
        // Apple Silicon, so it is deliberately not used as a fallback here.
        let current = intProperty(service, "NominalChargeCapacity")
            ?? intProperty(service, "AppleRawMaxCapacity")
            ?? 0
        cachedHealth = Self.health(currentCapacity: current, designCapacity: design)
    }

    /// Level, state and charging flag from an IOPS power-source description; nil when it
    /// carries no usable capacity (not a battery).
    static func reading(from description: [String: Any]) -> (level: Int, state: String, isCharging: Bool)? {
        guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let capacity = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, capacity > 0 else { return nil }

        let level = Int((current / capacity * 100).rounded())
        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        let isCharged = (description[kIOPSIsChargedKey] as? Bool) ?? false
        let powerState = description[kIOPSPowerSourceStateKey] as? String
        return (min(max(level, 0), 100),
                state(isCharging: isCharging, isCharged: isCharged, powerState: powerState),
                isCharging)
    }

    static func state(isCharging: Bool, isCharged: Bool, powerState: String?) -> String {
        if isCharging {
            return "Charging"
        } else if isCharged {
            return "Full"
        } else if powerState == kIOPSACPowerValue {
            return "AC Power"
        } else if powerState == kIOPSBatteryPowerValue {
            return "Discharging"
        } else {
            return "Unknown"
        }
    }

    /// Full-charge capacity as a percentage of design capacity, capped at 100; 0 when unknown.
    static func health(currentCapacity: Int, designCapacity: Int) -> Int {
        guard designCapacity > 0 && currentCapacity > 0 else { return 0 }
        return min(Int((Double(currentCapacity) / Double(designCapacity) * 100).rounded()), 100)
    }

    private func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = raw as? NSNumber else { return nil }
        return number.intValue
    }
}
