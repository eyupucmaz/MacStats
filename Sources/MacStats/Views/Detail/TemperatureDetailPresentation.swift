import Foundation

/// The Temperature page's text and derived data, kept out of the views so it can be tested.
enum TemperatureDetailPresentation {

    /// "53.4°C" and "53.4 degrees Celsius", as on the card and the chart. Celsius only (#20).
    static func celsius(_ value: Double, locale: Locale = .autoupdatingCurrent) -> (text: String, spoken: String) {
        (MetricValueFormat.short(value, unit: .celsius, locale: locale),
         MetricValueFormat.spoken(value, unit: .celsius, locale: locale))
    }

    static func title(of group: TemperatureSensorGroup) -> String {
        switch group {
        case .cpu: return L10n.string("CPU")
        case .performanceCores: return L10n.string("Performance cores")
        case .efficiencyCores: return L10n.string("Efficiency cores")
        case .gpu: return L10n.string("GPU")
        case .soc: return L10n.string("SoC / other")
        case .battery: return L10n.string("Battery")
        case .storage: return L10n.string("Storage")
        }
    }

    /// One sensor's row: now, and the session's lowest and highest reading.
    struct SensorRow: Equatable, Identifiable {
        /// "Sensor 3", numbered within its group; "CPU" for an unmapped Mac's single sensor.
        let label: String
        let key: String
        let now: String
        let low: String
        let high: String
        let spoken: String

        var id: String { key }
    }

    struct SensorGroup: Equatable, Identifiable {
        let group: TemperatureSensorGroup
        let title: String
        let rows: [SensorRow]
        /// The hottest current reading in the group.
        let hottest: String
        /// The lowest and highest session reading of any of its sensors.
        let low: String
        let high: String
        let spoken: String

        var id: Int { group.rawValue }
    }

    /// The report's readings grouped in page order. Each group shows its hottest sensor
    /// now and the session range of all its sensors.
    static func groups(_ report: TemperatureDetailReport, session: TemperatureSessionRange,
                       locale: Locale = .autoupdatingCurrent) -> [SensorGroup] {
        let byGroup = Dictionary(grouping: report.readings, by: \.sensor.group)
        return byGroup.keys.sorted().compactMap { group in
            guard let readings = byGroup[group], let hottest = readings.map(\.celsius).max() else { return nil }
            let title = title(of: group)
            let ranges = readings.map { range(of: $0, in: session) }
            let rows = zip(readings, ranges).enumerated().map { index, item in
                row(item.0, label: report.isMapped ? L10n.string("Sensor \(String(index + 1))") : title,
                    range: item.1, locale: locale)
            }
            let hot = celsius(hottest, locale: locale)
            let low = celsius(ranges.map(\.lowerBound).min() ?? hottest, locale: locale)
            let high = celsius(ranges.map(\.upperBound).max() ?? hottest, locale: locale)
            return SensorGroup(group: group, title: title, rows: rows, hottest: hot.text, low: low.text, high: high.text,
                               spoken: L10n.string("\(title), hottest \(hot.spoken), lowest \(low.spoken), highest \(high.spoken)"))
        }
    }

    /// The session range, always including the current reading (it may not be recorded yet).
    private static func range(of reading: TemperatureSensorReading, in session: TemperatureSessionRange) -> ClosedRange<Double> {
        let value = reading.celsius
        guard let range = session.range(for: reading.sensor.key) else { return value...value }
        return min(range.lowerBound, value)...max(range.upperBound, value)
    }

    private static func row(_ reading: TemperatureSensorReading, label: String, range: ClosedRange<Double>,
                            locale: Locale) -> SensorRow {
        let now = celsius(reading.celsius, locale: locale)
        let low = celsius(range.lowerBound, locale: locale)
        let high = celsius(range.upperBound, locale: locale)
        return SensorRow(label: label, key: reading.sensor.key, now: now.text, low: low.text, high: high.text,
                         spoken: L10n.string("\(label), \(now.spoken), lowest \(low.spoken), highest \(high.spoken)"))
    }
}

// MARK: - Thermal state band

/// The thermal state timeline laid out on a chart's time axis, for the strip under it.
struct ThermalStateBand: Equatable {
    struct Segment: Equatable, Identifiable {
        let start: Date
        let end: Date
        let level: CPUDetailPresentation.ThermalLevel

        var id: Date { start }
    }

    let domain: ClosedRange<Date>
    let segments: [Segment]

    /// Every known stretch of `timeline` inside `range` ending at `end`; the newest
    /// entry runs until `end`.
    init(timeline: ThermalStateTimeline, range: HistoryRange, end: Date) {
        let start = end.addingTimeInterval(-range.duration)
        domain = start...end
        let entries = timeline.entries
        segments = entries.enumerated().compactMap { index, entry in
            guard let level = entry.state.flatMap(CPUDetailPresentation.ThermalLevel.init) else { return nil }
            let next = index + 1 < entries.count ? entries[index + 1].date : end
            let from = max(entry.date, start)
            let to = min(next, end)
            return to > from ? Segment(start: from, end: to, level: level) : nil
        }
    }

    /// VoiceOver value: the share of the covered time in each state, most severe first,
    /// e.g. "Fair 25%, Nominal 75%".
    func summary(locale: Locale = .autoupdatingCurrent) -> String {
        let covered = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard covered > 0 else { return L10n.string("No readings yet") }
        let levels: [CPUDetailPresentation.ThermalLevel] = [.critical, .serious, .fair, .nominal]
        return levels.compactMap { level in
            let time = segments.filter { $0.level == level }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            guard time > 0 else { return nil }
            return "\(level.text) \(MetricFormat.percent(time / covered * 100, digits: 0, locale: locale))"
        }
        .joined(separator: ", ")
    }
}
