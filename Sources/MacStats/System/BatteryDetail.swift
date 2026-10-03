import Foundation
import IOKit.ps

/// Charging state as the battery card reports it, typed for the detail page.
enum BatteryChargeState: Equatable {
    case charging, full, acPower, discharging

    /// From `BatteryMetrics.state`, so the page and the card always agree; nil for "Unknown".
    init?(engineState: String) {
        switch engineState {
        case "Charging": self = .charging
        case "Full": self = .full
        case "AC Power": self = .acPower
        case "Discharging": self = .discharging
        default: return nil
        }
    }

    /// The identifier `BatteryMetrics` and `StatCardFactory` use for this state.
    var engineState: String {
        switch self {
        case .charging: return "Charging"
        case .full: return "Full"
        case .acPower: return "AC Power"
        case .discharging: return "Discharging"
        }
    }

    var powerState: BatteryPowerState {
        switch self {
        case .charging: return .charging
        case .full, .acPower: return .pluggedIn
        case .discharging: return .onBattery
        }
    }
}

/// What the charge chart's band shows: where the Mac drew power from at each reading.
/// Recorded into history as `historyValue`.
enum BatteryPowerState: Int, CaseIterable, Equatable {
    case onBattery = 0
    case pluggedIn = 1
    case charging = 2

    var historyValue: Double { Double(rawValue) }

    init?(historyValue: Double) {
        guard historyValue.isFinite, let state = Self(rawValue: Int(historyValue.rounded())) else { return nil }
        self = state
    }
}

/// How long until the battery is full (charging) or empty (on battery).
enum BatteryTimeRemaining: Equatable {
    case untilFull(minutes: Int)
    case untilEmpty(minutes: Int)

    var minutes: Int {
        switch self {
        case .untilFull(let minutes), .untilEmpty(let minutes): return minutes
        }
    }
}

/// Whether macOS considers the battery healthy.
enum BatteryCondition: Equatable {
    case normal, serviceRecommended
}

/// Where the Mac is drawing power from right now (`IOPSGetProvidingPowerSourceType`).
enum PowerSourceKind: Equatable {
    case ac, battery, ups

    init?(_ value: String?) {
        switch value {
        case kIOPSACPowerValue: self = .ac
        case kIOPSBatteryPowerValue: self = .battery
        case "UPS Power": self = .ups  // kIOPMUPSPowerKey; IOPSKeys.h has no constant for it
        default: return nil
        }
    }
}

/// The connected power adapter, from `IOPSCopyExternalPowerAdapterDetails`.
struct PowerAdapterInfo: Equatable {
    /// e.g. "70W USB-C Power Adapter"; third-party chargers often have none.
    var name: String?
    /// What the adapter negotiated, e.g. 68 for a 70 W adapter.
    var watts: Int?
}

/// Everything the Battery page shows that the engine does not record. Each value is
/// nil when the hardware or macOS does not report it, so the page hides it.
struct BatteryDetail: Equatable {
    struct Battery: Equatable {
        var level: Int
        var state: BatteryChargeState?
        /// Nil while macOS is still calculating, when full, and when not reported.
        var timeRemaining: BatteryTimeRemaining?
        /// Voltage × current at the battery: positive while charging, negative while discharging.
        var watts: Double?
        var voltage: Double?            // volts
        var temperature: Double?        // °C
        var cycleCount: Int?
        var designCycleCount: Int?
        var maximumCapacity: Int?       // mAh
        var designCapacity: Int?        // mAh
        /// Maximum over design capacity, the same figure the battery card uses.
        var health: Int?                // percent
        var condition: BatteryCondition?
    }

    /// Nil on Macs without a battery (desktops).
    var battery: Battery?
    var powerSource: PowerSourceKind?
    var adapterConnected: Bool?
    /// Nil when no adapter is connected or macOS reports nothing about it.
    var adapter: PowerAdapterInfo?
}

/// The unparsed readings one sample is built from, injectable for tests.
struct BatteryDetailRaw {
    /// The first IOPS power source with a capacity — the one the card shows.
    var powerSource: [String: Any]?
    /// `IOPSGetProvidingPowerSourceType`, e.g. "AC Power".
    var providingSource: String?
    /// `IOPSGetTimeRemainingEstimate`: seconds, or `kIOPSTimeRemainingUnknown` (-1)
    /// while calculating, or `kIOPSTimeRemainingUnlimited` (-2) on AC.
    var timeRemainingEstimate: Double?
    /// AppleSmartBattery registry properties (`SmartBatteryKey`); nil without the service.
    var registry: [String: Any]?
    /// `IOPSCopyExternalPowerAdapterDetails`.
    var adapter: [String: Any]?
}

/// The AppleSmartBattery properties the page reads (`ioreg -r -c AppleSmartBattery -l`).
/// They are not API: each is optional and validated before use. Checked on an Apple M5
/// MacBook (macOS 26); Intel gauges publish the same names.
enum SmartBatteryKey {
    /// mV.
    static let voltage = "Voltage"
    /// mA, averaged by the gauge; positive into the battery. Signed, but stored by some
    /// Macs as the 32-bit two's complement (e.g. 4294966000 for -1296).
    static let amperage = "Amperage"
    /// Hundredths of a degree Celsius (3065 = 30.65 °C).
    static let temperature = "Temperature"
    static let cycleCount = "CycleCount"
    static let designCycleCount = "DesignCycleCount9C"
    /// mAh, as built.
    static let designCapacity = "DesignCapacity"
    /// mAh: the full-charge capacity plus the pack reserve (`AppleRawMaxCapacity` +
    /// `PackReserve`). `BatteryMetrics` computes the card's health from it.
    static let nominalChargeCapacity = "NominalChargeCapacity"
    /// mAh: the gauge's full-charge capacity; the fallback when there is no nominal one.
    /// ("MaxCapacity" is a percentage on Apple silicon and is not used.)
    static let rawMaxCapacity = "AppleRawMaxCapacity"
    /// Non-zero when the gauge has latched a permanent failure.
    static let permanentFailureStatus = "PermanentFailureStatus"
    /// Minutes; 65535 when not applicable.
    static let averageTimeToFull = "AvgTimeToFull"
    static let averageTimeToEmpty = "AvgTimeToEmpty"
    static let timeRemaining = "TimeRemaining"
    static let externalConnected = "ExternalConnected"

    static let all = [voltage, amperage, temperature, cycleCount, designCycleCount, designCapacity,
                      nominalChargeCapacity, rawMaxCapacity, permanentFailureStatus,
                      averageTimeToFull, averageTimeToEmpty, timeRemaining, externalConnected]
}

extension BatteryDetail {

    /// Builds a sample from raw readings. No battery when IOPS lists none with a capacity
    /// (the card's rule), even if an AppleSmartBattery service exists.
    static func make(_ raw: BatteryDetailRaw) -> BatteryDetail {
        var detail = BatteryDetail()
        detail.powerSource = PowerSourceKind(raw.providingSource)
        detail.adapter = adapter(from: raw.adapter)

        if let description = raw.powerSource, let reading = BatteryMetrics.reading(from: description) {
            detail.battery = battery(level: reading.level,
                                     state: BatteryChargeState(engineState: reading.state),
                                     description: description,
                                     registry: raw.registry ?? [:],
                                     estimate: raw.timeRemainingEstimate)
        }

        if let connected = raw.registry?[SmartBatteryKey.externalConnected] as? Bool {
            detail.adapterConnected = connected
        } else if detail.adapter != nil {
            detail.adapterConnected = true
        } else if let state = raw.powerSource?[kIOPSPowerSourceStateKey] as? String {
            detail.adapterConnected = state == kIOPSACPowerValue
        }
        if detail.adapterConnected == false { detail.adapter = nil }
        return detail
    }

    private static func battery(level: Int, state: BatteryChargeState?, description: [String: Any],
                                registry: [String: Any], estimate: Double?) -> Battery {
        let voltage = int(registry[SmartBatteryKey.voltage]).flatMap { $0 > 0 ? $0 : nil }
        let amperage = int(registry[SmartBatteryKey.amperage]).map(signed32)
        let design = positive(registry[SmartBatteryKey.designCapacity])
        let maximum = positive(registry[SmartBatteryKey.nominalChargeCapacity])
            ?? positive(registry[SmartBatteryKey.rawMaxCapacity])
        let health = BatteryMetrics.health(currentCapacity: maximum ?? 0, designCapacity: design ?? 0)

        var battery = Battery(level: level, state: state)
        battery.voltage = voltage.map { Double($0) / 1_000 }
        battery.watts = watts(millivolts: voltage, milliamps: amperage)
        battery.temperature = temperature(registry[SmartBatteryKey.temperature])
        battery.cycleCount = int(registry[SmartBatteryKey.cycleCount]).flatMap { $0 >= 0 ? $0 : nil }
        battery.designCycleCount = positive(registry[SmartBatteryKey.designCycleCount])
            ?? positive(description["DesignCycleCount"])
        battery.maximumCapacity = maximum
        battery.designCapacity = design
        battery.health = health > 0 ? health : nil
        battery.condition = condition(healthCondition: description[kIOPSBatteryHealthConditionKey] as? String,
                                      permanentFailure: int(registry[SmartBatteryKey.permanentFailureStatus]),
                                      health: description[kIOPSBatteryHealthKey] as? String)
        battery.timeRemaining = timeRemaining(
            state: state,
            estimate: estimate,
            timeToFull: int(description[kIOPSTimeToFullChargeKey]),
            timeToEmpty: int(description[kIOPSTimeToEmptyKey]),
            averageTimeToFull: int(registry[SmartBatteryKey.averageTimeToFull]),
            averageTimeToEmpty: int(registry[SmartBatteryKey.averageTimeToEmpty]),
            gaugeTimeRemaining: int(registry[SmartBatteryKey.timeRemaining]))
        return battery
    }

    // MARK: - Derivations

    /// Watts from mV × mA, signed like the current; nil without both readings or for a
    /// reading no laptop battery could deliver.
    static func watts(millivolts: Int?, milliamps: Int?) -> Double? {
        guard let millivolts, let milliamps, millivolts > 0 else { return nil }
        let watts = Double(millivolts) * Double(milliamps) / 1_000_000
        return abs(watts) <= 300 ? watts : nil
    }

    /// Reads a 32-bit two's-complement value stored unsigned (4294966000 → -1296);
    /// anything else is returned unchanged.
    static func signed32(_ value: Int) -> Int {
        (Int(Int32.max) + 1 ... Int(UInt32.max)).contains(value) ? Int(Int32(truncatingIfNeeded: value)) : value
    }

    /// Hundredths of a degree to °C; nil outside what a working battery reports.
    static func temperature(_ raw: Any?) -> Double? {
        guard let hundredths = int(raw) else { return nil }
        let celsius = Double(hundredths) / 100
        return (-20 ... 100).contains(celsius) && hundredths != 0 ? celsius : nil
    }

    /// The condition macOS would show. A latched failure flag or a non-empty
    /// `BatteryHealthCondition` means service; otherwise `PermanentFailureStatus` == 0
    /// reads as normal. IOPS' `BatteryHealth` is used only when the gauge has no
    /// failure flag (Intel): on Apple silicon it can say "Check Battery" for a battery
    /// System Information calls normal.
    static func condition(healthCondition: String?, permanentFailure: Int?, health: String?) -> BatteryCondition? {
        if let healthCondition, !healthCondition.trimmingCharacters(in: .whitespaces).isEmpty {
            return .serviceRecommended
        }
        if let permanentFailure { return permanentFailure == 0 ? .normal : .serviceRecommended }
        switch health {
        case kIOPSGoodValue: return .normal
        case kIOPSFairValue, kIOPSPoorValue: return .serviceRecommended
        default: return nil
        }
    }

    /// Time to full while charging, to empty on battery; nil while macOS is still
    /// calculating (`-1`), when full or on AC without charging, and when nothing is
    /// reported. IOPS — what the menu bar battery shows — wins; the gauge's averages
    /// are used only when IOPS has no figure at all, never to replace a "calculating".
    static func timeRemaining(state: BatteryChargeState?, estimate: Double?,
                              timeToFull: Int?, timeToEmpty: Int?,
                              averageTimeToFull: Int?, averageTimeToEmpty: Int?,
                              gaugeTimeRemaining: Int?) -> BatteryTimeRemaining? {
        func valid(_ minutes: Int?) -> Int? {
            guard let minutes, minutes > 0, minutes < 65_535 else { return nil }
            return minutes
        }
        switch state {
        case .charging:
            if let timeToFull { return valid(timeToFull).map { .untilFull(minutes: $0) } }
            return valid(averageTimeToFull ?? gaugeTimeRemaining).map { .untilFull(minutes: $0) }
        case .discharging:
            if let estimate {
                if estimate > 0 { return valid(Int((estimate / 60).rounded())).map { .untilEmpty(minutes: $0) } }
                if estimate == timeRemainingUnknown { return nil }
            }
            if let timeToEmpty { return valid(timeToEmpty).map { .untilEmpty(minutes: $0) } }
            return valid(averageTimeToEmpty ?? gaugeTimeRemaining).map { .untilEmpty(minutes: $0) }
        default:
            return nil
        }
    }

    /// `kIOPSTimeRemainingUnknown`, a cast macro Swift does not import.
    static let timeRemainingUnknown: Double = -1

    static func adapter(from details: [String: Any]?) -> PowerAdapterInfo? {
        guard let details else { return nil }
        // "Name" is undocumented but what System Information shows; the documented keys stop at "Watts".
        let name = (details["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = PowerAdapterInfo(name: name?.isEmpty == false ? name : nil,
                                    watts: positive(details[kIOPSPowerAdapterWattsKey]))
        return info.name == nil && info.watts == nil ? nil : info
    }

    private static func int(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        return number.intValue
    }

    private static func positive(_ raw: Any?) -> Int? {
        int(raw).flatMap { $0 > 0 ? $0 : nil }
    }
}
