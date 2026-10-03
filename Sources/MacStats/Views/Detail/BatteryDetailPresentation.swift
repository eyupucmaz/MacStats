import Foundation

/// History series the battery page records itself while it is visible, on top of the
/// core `battery.level` the engine records every tick.
enum BatteryDetailSeries {
    /// Battery power in watts, + charging / − discharging.
    static let watts = "battery.watts"
    /// `BatteryPowerState.historyValue`: 0 on battery, 1 plugged in, 2 charging.
    static let state = "battery.state"
}

/// The battery page's text, kept out of the views so it can be tested.
enum BatteryDetailFormat {

    /// A card state as a standalone label. The card's strings are written to follow a
    /// comma ("Battery 80 percent, charging"), so the first letter is raised here.
    static func stateTitle(_ state: BatteryChargeState?, locale: Locale = .autoupdatingCurrent) -> String {
        sentenceCase(StatCardFactory.batteryStateText(state?.engineState ?? "Unknown"), locale: locale)
    }

    static func powerStateTitle(_ state: BatteryPowerState, locale: Locale = .autoupdatingCurrent) -> String {
        switch state {
        case .charging: return stateTitle(.charging, locale: locale)
        case .pluggedIn: return stateTitle(.acPower, locale: locale)
        case .onBattery: return stateTitle(.discharging, locale: locale)
        }
    }

    static func sentenceCase(_ text: String, locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    /// "2 h 15 min" / "45 min", and the spoken "2 hours, 15 minutes".
    static func duration(minutes: Int) -> (text: String, spoken: String) {
        let hours = minutes / 60, rest = minutes % 60
        func spokenHours(_ n: Int) -> String { n == 1 ? L10n.string("\(String(n)) hour") : L10n.string("\(String(n)) hours") }
        func spokenMinutes(_ n: Int) -> String {
            n == 1 ? L10n.string("\(String(n)) minute") : L10n.string("\(String(n)) minutes")
        }
        if hours > 0 {
            return (L10n.string("\(String(hours)) h \(String(rest)) min"), "\(spokenHours(hours)), \(spokenMinutes(rest))")
        }
        return (L10n.string("\(String(rest)) min"), spokenMinutes(rest))
    }

    static func timeTitle(_ time: BatteryTimeRemaining) -> String {
        switch time {
        case .untilFull: return L10n.string("Until full")
        case .untilEmpty: return L10n.string("Remaining")
        }
    }

    /// Signed battery power, "+12.3 W" while charging, "−8.1 W" while discharging, "0 W" idle.
    static func signedWatts(_ watts: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let magnitude = abs(watts)
        let digits = magnitude < 9.95 ? 1 : 0
        let number = MetricFormat.decimal(magnitude, digits: digits, locale: locale)
        guard (magnitude * (digits == 1 ? 10 : 1)).rounded() > 0 else { return "0 W" }
        return (watts > 0 ? "+" : "\u{2212}") + number + " W"
    }

    /// "12.3 watts into the battery" / "8.1 watts from the battery".
    static func spokenWatts(_ watts: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let amount = MetricValueFormat.spoken(abs(watts), unit: .watts, locale: locale)
        return watts >= 0 ? L10n.string("\(amount) into the battery") : L10n.string("\(amount) from the battery")
    }

    static func milliampHours(_ value: Int, locale: Locale = .autoupdatingCurrent) -> (text: String, spoken: String) {
        let number = MetricFormat.decimal(Double(value), digits: 0, locale: locale)
        return (L10n.string("\(number) mAh"), L10n.string("\(number) milliampere-hours"))
    }

    static func volts(_ value: Double, locale: Locale = .autoupdatingCurrent) -> (text: String, spoken: String) {
        let number = MetricFormat.decimal(value, digits: 2, locale: locale)
        return (L10n.string("\(number) V"), L10n.string("\(number) volts"))
    }

    static func condition(_ condition: BatteryCondition) -> String {
        switch condition {
        case .normal: return L10n.string("Normal")
        case .serviceRecommended: return L10n.string("Service recommended")
        }
    }

    static func powerSource(_ source: PowerSourceKind) -> String {
        switch source {
        case .ac: return L10n.string("AC power")
        case .battery: return L10n.string("Battery")
        case .ups: return L10n.string("UPS")
        }
    }
}

/// One label / value row of the page's lists.
struct BatteryDetailRow: Equatable, Identifiable {
    let label: String
    let value: String
    let spoken: String

    var id: String { label }

    init(label: String, value: String, spoken: String? = nil) {
        self.label = label
        self.value = value
        self.spoken = spoken ?? value
    }

    /// Adapter status, name and wattage. Desktops without a battery also get the
    /// power source; a laptop's state already says it.
    static func power(_ detail: BatteryDetail, locale: Locale = .autoupdatingCurrent) -> [BatteryDetailRow] {
        var rows: [BatteryDetailRow] = []
        if detail.battery == nil, let source = detail.powerSource {
            rows.append(BatteryDetailRow(label: L10n.string("Power source"), value: BatteryDetailFormat.powerSource(source)))
        }
        // A laptop's section is the adapter's own; a desktop's "Power" section names it.
        if let connected = detail.adapterConnected, detail.battery != nil || detail.adapter != nil {
            rows.append(BatteryDetailRow(label: detail.battery != nil ? L10n.string("Status") : L10n.string("Power adapter"),
                                         value: connected ? L10n.string("Connected") : L10n.string("Not connected")))
        }
        if let name = detail.adapter?.name {
            rows.append(BatteryDetailRow(label: L10n.string("Name"), value: name))
        }
        if let watts = detail.adapter?.watts {
            rows.append(BatteryDetailRow(label: L10n.string("Wattage"),
                                         value: MetricValueFormat.short(Double(watts), unit: .watts, locale: locale),
                                         spoken: MetricValueFormat.spoken(Double(watts), unit: .watts, locale: locale)))
        }
        return rows
    }

    /// Condition, capacities, cycles, temperature and voltage; each hidden when unknown.
    static func health(_ battery: BatteryDetail.Battery, locale: Locale = .autoupdatingCurrent) -> [BatteryDetailRow] {
        var rows: [BatteryDetailRow] = []
        if let condition = battery.condition {
            rows.append(BatteryDetailRow(label: L10n.string("Condition"), value: BatteryDetailFormat.condition(condition)))
        }
        if let health = battery.health {
            let value = MetricFormat.percent(Double(health), digits: 0, locale: locale)
            rows.append(BatteryDetailRow(label: L10n.string("Health"), value: value,
                                         spoken: L10n.string("\(String(health)) percent")))
        }
        if let maximum = battery.maximumCapacity {
            let text = BatteryDetailFormat.milliampHours(maximum, locale: locale)
            rows.append(BatteryDetailRow(label: L10n.string("Maximum capacity"), value: text.text, spoken: text.spoken))
        }
        if let design = battery.designCapacity {
            let text = BatteryDetailFormat.milliampHours(design, locale: locale)
            rows.append(BatteryDetailRow(label: L10n.string("Design capacity"), value: text.text, spoken: text.spoken))
        }
        if let cycles = battery.cycleCount {
            if let design = battery.designCycleCount {
                rows.append(BatteryDetailRow(label: L10n.string("Cycle count"),
                                             value: L10n.string("\(String(cycles)) of \(String(design))")))
            } else {
                rows.append(BatteryDetailRow(label: L10n.string("Cycle count"), value: String(cycles)))
            }
        }
        if let temperature = battery.temperature {
            rows.append(BatteryDetailRow(label: L10n.string("Temperature"),
                                         value: MetricValueFormat.short(temperature, unit: .celsius, locale: locale),
                                         spoken: MetricValueFormat.spoken(temperature, unit: .celsius, locale: locale)))
        }
        if let voltage = battery.voltage {
            let text = BatteryDetailFormat.volts(voltage, locale: locale)
            rows.append(BatteryDetailRow(label: L10n.string("Voltage"), value: text.text, spoken: text.spoken))
        }
        return rows
    }
}

/// The strip under the charge chart: runs of one power state over the visible range.
/// Each reading holds until the next stored entry (a reading or a gap marker), the
/// newest one for one sampling interval, so time the page was not open stays blank.
struct BatteryStateBand: Equatable {
    struct Segment: Equatable, Identifiable {
        let start: Date
        let end: Date
        let state: BatteryPowerState

        var id: Date { start }
    }

    let domain: ClosedRange<Date>
    let segments: [Segment]

    init(points: [MetricPoint], range: HistoryRange, end: Date, interval: TimeInterval) {
        let start = end.addingTimeInterval(-range.duration)
        domain = start...end
        var segments: [Segment] = []
        for (index, point) in points.enumerated() {
            guard let value = point.value, let state = BatteryPowerState(historyValue: value) else { continue }
            let next = index + 1 < points.count ? points[index + 1].date : point.date.addingTimeInterval(interval)
            let from = max(point.date, start)
            let to = min(next, end)
            guard to > from else { continue }
            if let last = segments.last, last.state == state, last.end == from {
                segments[segments.count - 1] = Segment(start: last.start, end: to, state: state)
            } else {
                segments.append(Segment(start: from, end: to, state: state))
            }
        }
        self.segments = segments
    }

    /// Share of the covered time in each state, charging first.
    var shares: [(state: BatteryPowerState, fraction: Double)] {
        let covered = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard covered > 0 else { return [] }
        return BatteryPowerState.allCases.reversed().compactMap { state in
            let time = segments.filter { $0.state == state }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            return time > 0 ? (state, time / covered) : nil
        }
    }

    /// VoiceOver value, e.g. "Charging 75%, Discharging 25%".
    func summary(locale: Locale = .autoupdatingCurrent) -> String {
        let shares = shares
        guard !shares.isEmpty else { return L10n.string("No readings yet") }
        return shares.map {
            "\(BatteryDetailFormat.powerStateTitle($0.state, locale: locale)) \(MetricFormat.percent($0.fraction * 100, digits: 0, locale: locale))"
        }.joined(separator: ", ")
    }
}

/// The signed power series split into two non-negative ones the shared chart can draw
/// (its axis starts at zero): charging readings in one, discharging magnitudes in the
/// other, each with gaps where the other applies. Idle readings (0 W) count as charging.
struct BatteryPowerSplit: Equatable {
    static let chargingID = "battery.watts.charging"
    static let dischargingID = "battery.watts.discharging"

    let charging: MetricSeries
    let discharging: MetricSeries

    init(_ series: MetricSeries?) {
        let points = series?.points ?? []
        charging = MetricSeries(id: Self.chargingID, unit: .watts, points: points.map {
            MetricPoint(date: $0.date, value: $0.value.flatMap { $0 >= 0 ? $0 : nil })
        })
        discharging = MetricSeries(id: Self.dischargingID, unit: .watts, points: points.map {
            MetricPoint(date: $0.date, value: $0.value.flatMap { $0 < 0 ? -$0 : nil })
        })
    }

    /// The halves that have any reading, charging first.
    var drawn: [MetricSeries] {
        [charging, discharging].filter { $0.points.contains { $0.value != nil } }
    }

    static func statistics(_ series: MetricSeries) -> SeriesStatistics? {
        let values = series.points.compactMap(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        return SeriesStatistics(min: low, average: values.reduce(0, +) / Double(values.count), max: high)
    }
}
