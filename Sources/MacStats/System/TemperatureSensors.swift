import Foundation

/// Where a temperature sensor sits, in the order the Temperature page (#32) lists them.
enum TemperatureSensorGroup: Int, CaseIterable, Comparable {
    /// Intel Macs (no core types), and the card's single sensor on an unmapped Mac.
    case cpu
    case performanceCores
    case efficiencyCores
    case gpu
    /// The rest of the SoC or logic board: fabric, wireless and similar.
    case soc
    case battery
    case storage

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TemperatureSensor: Equatable, Identifiable {
    let key: String
    let group: TemperatureSensorGroup

    var id: String { key }
}

/// The chip families with a mapped sensor list.
enum TemperatureChipFamily: String, CaseIterable {
    case m1, m2, m3, m4, m5, intel

    /// From `machdep.cpu.brand_string`: "Apple M3 Pro" → `.m3`, "Intel(R) Core(TM)
    /// i7-9750H …" → `.intel`. Nil for anything else, including Apple chips newer than
    /// the catalogue, which then fall back to the card's single sensor.
    init?(chipName: String?) {
        guard let name = chipName?.trimmingCharacters(in: .whitespaces) else { return nil }
        if name.hasPrefix("Intel") {
            self = .intel
            return
        }
        guard name.hasPrefix("Apple M") else { return nil }
        let digits = name.dropFirst("Apple M".count).prefix { $0.isNumber }
        guard let generation = Int(digits), let family = Self(rawValue: "m\(generation)") else { return nil }
        self = family
    }
}

/// The SMC temperature keys of each chip family, grouped for the Temperature page.
///
/// Provenance (keep this up to date when adding keys):
/// - **M5** — confirmed on an Apple M5 MacBook Pro (Mac17,2) by enumerating its SMC
///   read-only: every key below exists and reads plausibly. Which `Tp` keys are
///   performance and which efficiency cores is inferred: eight run hottest under load
///   (two per performance core) and six cooler, matching the six efficiency cores.
///   The `Te`/`Ts` keys are other SoC sensors; their exact positions are not documented.
/// - **M1–M4** and **Intel** — keys as published by open-source monitoring tools
///   (e.g. Stats), not verified on hardware here. Pro / Max / Ultra variants have more
///   cores, so their lists are a superset of the base chip's.
/// - Battery (`TB*T`), storage (`TH0*`) and wireless (`TW0P`) are shared across
///   Apple silicon; confirmed on the M5.
///
/// A key a Mac lacks costs nothing after the first sample (the SMC's "not found" is
/// cached by `SMCService`) and simply isn't shown; readings outside
/// `SMCService.isPlausibleTemperature` are dropped every sample.
enum TemperatureSensorCatalog {

    static func sensors(for family: TemperatureChipFamily) -> [TemperatureSensor] {
        switch family {
        case .m1:
            return sensors(.performanceCores, "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b")
                + sensors(.efficiencyCores, "Tp09", "Tp0T")
                + sensors(.gpu, "Tg05", "Tg0D", "Tg0L", "Tg0T")
                + appleSiliconShared
        case .m2:
            return sensors(.performanceCores, "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j")
                + sensors(.efficiencyCores, "Tp1h", "Tp1t", "Tp1p", "Tp1l")
                + sensors(.gpu, "Tg0f", "Tg0j")
                + appleSiliconShared
        case .m3:
            return sensors(.performanceCores, "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                           "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E")
                + sensors(.efficiencyCores, "Te05", "Te0L", "Te0P", "Te0S")
                + sensors(.gpu, "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A")
                + appleSiliconShared
        case .m4:
            return sensors(.performanceCores, "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e")
                + sensors(.efficiencyCores, "Te05", "Te0S", "Te09", "Te0H")
                + sensors(.gpu, "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k")
                + appleSiliconShared
        case .m5:
            return sensors(.performanceCores, "Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a")
                + sensors(.efficiencyCores, "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E")
                + sensors(.gpu, "Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
                          "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p", "Tg12", "Tg16", "Tg1A",
                          "Tg1I", "Tg1M", "Tg1Y", "Tg1c", "Tg1g", "Tg1o", "Tg1s")
                + sensors(.soc, "Te04", "Te08", "Te0C", "Te0R",
                          "Ts00", "Ts04", "Ts08", "Ts0C", "Ts0G", "Ts0K", "Ts0O", "Ts0R")
                + appleSiliconShared
        case .intel:
            // CPU proximity and die, then one sensor per core; GPU proximity and die;
            // platform controller hub, memory and wireless.
            return sensors(.cpu, "TC0P", "TC0D", "TC0E", "TC0F",
                           "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", "TC8C")
                + sensors(.gpu, "TG0P", "TG0D")
                + sensors(.soc, "TPCD", "TM0P", "TW0P")
                + sensors(.battery, "TB0T", "TB1T", "TB2T")
                + sensors(.storage, "TH0P", "TH0a", "TH0b", "TH0x")
        }
    }

    private static let appleSiliconShared =
        sensors(.soc, "TW0P")
        + sensors(.battery, "TB0T", "TB1T", "TB2T")
        + sensors(.storage, "TH0x", "TH0A", "TH0B", "TH0a", "TH0b")

    private static func sensors(_ group: TemperatureSensorGroup, _ keys: String...) -> [TemperatureSensor] {
        keys.map { TemperatureSensor(key: $0, group: group) }
    }
}

// MARK: - Reading

struct TemperatureSensorReading: Equatable, Identifiable {
    let sensor: TemperatureSensor
    /// Degrees Celsius, always plausible.
    let celsius: Double

    var id: String { sensor.key }
}

/// One sample of every sensor the Temperature page shows.
struct TemperatureDetailReport: Equatable {
    /// False when this Mac's sensors are not mapped (or none of them reads), so the
    /// page shows only the card's sensor.
    var isMapped: Bool
    var readings: [TemperatureSensorReading]
}

/// Where `TemperatureSensorReader` gets its readings, injectable for tests.
protocol TemperatureSensorSource: AnyObject {
    /// The decoded value of a key in °C, plausible or not; nil when missing.
    func temperature(key: String) -> Double?
    /// The key behind the card's reading, once the engine has probed one.
    var primaryKey: String? { get }
}

final class LiveTemperatureSensorSource: TemperatureSensorSource {
    func temperature(key: String) -> Double? { SMCService.shared.readTemperature(key: key) }
    var primaryKey: String? { SMCService.shared.activeTemperatureKey }
}

enum TemperatureSensorReader {
    /// Reads `sensors` and keeps the plausible ones. With nothing mapped or nothing
    /// readable, falls back to the card's own key, shown under `.cpu`.
    static func read(_ sensors: [TemperatureSensor], from source: TemperatureSensorSource) -> TemperatureDetailReport {
        let readings = sensors.compactMap { sensor in
            plausible(source.temperature(key: sensor.key)).map { TemperatureSensorReading(sensor: sensor, celsius: $0) }
        }
        if !readings.isEmpty { return TemperatureDetailReport(isMapped: true, readings: readings) }

        guard let key = source.primaryKey, let value = plausible(source.temperature(key: key)) else {
            return TemperatureDetailReport(isMapped: false, readings: [])
        }
        let sensor = TemperatureSensor(key: key, group: .cpu)
        return TemperatureDetailReport(isMapped: false, readings: [TemperatureSensorReading(sensor: sensor, celsius: value)])
    }

    private static func plausible(_ value: Double?) -> Double? {
        guard let value, SMCService.isPlausibleTemperature(value) else { return nil }
        return value
    }
}

// MARK: - Session range

/// The lowest and highest reading of each sensor this session. "Session" means the
/// samples the Temperature page took since MacStats started: the page samples only
/// while it is visible, so time spent on other pages is not covered. Nothing is saved.
struct TemperatureSessionRange: Equatable {
    private(set) var ranges: [String: ClosedRange<Double>] = [:]

    mutating func record(_ readings: [TemperatureSensorReading]) {
        for reading in readings {
            let value = reading.celsius
            if let range = ranges[reading.sensor.key] {
                ranges[reading.sensor.key] = min(range.lowerBound, value)...max(range.upperBound, value)
            } else {
                ranges[reading.sensor.key] = value...value
            }
        }
    }

    func range(for key: String) -> ClosedRange<Double>? { ranges[key] }
}

// MARK: - Thermal state timeline

/// The thermal states macOS reported while the Temperature page was open, for the
/// band under its chart. Kept for the history window (one hour) across visits.
struct ThermalStateTimeline: Equatable {
    struct Entry: Equatable {
        let date: Date
        /// Nil marks the end of a visit: the state is unknown from here on.
        let state: ProcessInfo.ThermalState?
    }

    private(set) var entries: [Entry] = []

    /// Appends a change (repeats of the current state are ignored) and forgets what
    /// fell out of the window, keeping the entry the window starts in.
    mutating func record(_ state: ProcessInfo.ThermalState?, at date: Date,
                         window: TimeInterval = MetricHistory.window) {
        if let last = entries.last {
            if date < last.date { entries.removeAll() }  // the clock went backwards
            else if last.state == state { return }
        } else if state == nil {
            return
        }
        entries.append(Entry(date: date, state: state))
        let cutoff = date.addingTimeInterval(-window)
        if let firstInside = entries.firstIndex(where: { $0.date >= cutoff }), firstInside > 1 {
            entries.removeFirst(firstInside - 1)
        }
    }
}
