import Foundation

/// History series the memory page records itself, on top of the core
/// `memory.used` / `memory.pressure` the engine records every tick.
enum MemoryDetailSeries {
    /// `MemoryPressureLevel.severity` (0 normal, 1 warning, 2 critical), recorded
    /// by `MemoryDetailSampler` while the page is visible.
    static let pressureLevel = "memory.pressureLevel"
}

/// RAM sizes in binary units labelled KB / MB / GB, as Activity Monitor and the
/// memory card show them (16 GiB reads "16 GB").
enum MemoryDetailFormat {
    /// e.g. "16 KB", "812 MB", "2.6 GB". One decimal for GB below 100, none otherwise;
    /// the unit steps up once rounding reaches 1000, so 999.6 MB reads "1.0 GB".
    static func bytes(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = scale(bytes, locale: locale)
        return "\(scaled.number) \(scaled.unit.symbol)"
    }

    /// Spelled-out form for VoiceOver, e.g. "2.6 gigabytes".
    static func spokenBytes(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = scale(bytes, locale: locale)
        return "\(scaled.number) \(scaled.unit.spoken)"
    }

    /// Installed RAM in whole gigabytes ("16 GB"), as About This Mac shows it.
    static func installed(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        guard gigabytes >= 1 else { return self.bytes(bytes, locale: locale) }
        return MetricFormat.decimal(gigabytes, digits: 0, locale: locale) + " GB"
    }

    static func spokenInstalled(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        guard gigabytes >= 1 else { return spokenBytes(bytes, locale: locale) }
        return "\(MetricFormat.decimal(gigabytes, digits: 0, locale: locale)) \(MetricFormat.ByteUnit.giga.spoken)"
    }

    private static func scale(_ bytes: UInt64, locale: Locale) -> (number: String, unit: MetricFormat.ByteUnit) {
        let units = MetricFormat.ByteUnit.allCases
        for (power, unit) in units.enumerated() {
            let value = Double(bytes) / pow(1_024, Double(power))
            let digits = power >= 3 && value < 99.95 ? 1 : 0
            let step = digits == 0 ? 1.0 : 10.0
            if (value * step).rounded() / step < 1_000 || unit == units.last {
                return (MetricFormat.decimal(value, digits: digits, locale: locale), unit)
            }
        }
        return ("0", .byte)
    }
}

extension MemoryPressureLevel {
    var title: String {
        switch self {
        case .normal: return L10n.string("Normal")
        case .warning: return L10n.string("Warning")
        case .critical: return L10n.string("Critical")
        }
    }
}

extension MemoryBreakdown.Category {
    var title: String {
        switch self {
        case .app: return L10n.string("App memory")
        case .wired: return L10n.string("Wired")
        case .compressed: return L10n.string("Compressed")
        case .cached: return L10n.string("Cached files")
        case .free: return L10n.string("Free")
        }
    }
}

/// The pressure-level strip under the pressure chart: runs of one kernel level over
/// the visible range. Each reading holds until the next stored entry (a reading or a
/// gap marker), the newest one for one sampling interval, so time the page was not
/// open stays blank rather than being painted with a guessed level.
struct MemoryPressureBand: Equatable {
    struct Segment: Equatable, Identifiable {
        let start: Date
        let end: Date
        let level: MemoryPressureLevel

        var id: Date { start }
    }

    let domain: ClosedRange<Date>
    let segments: [Segment]

    init(points: [MetricPoint], range: HistoryRange, end: Date, interval: TimeInterval) {
        let start = end.addingTimeInterval(-range.duration)
        domain = start...end
        var segments: [Segment] = []
        for (index, point) in points.enumerated() {
            guard let value = point.value, let level = MemoryPressureLevel(severity: value) else { continue }
            let next = index + 1 < points.count ? points[index + 1].date : point.date.addingTimeInterval(interval)
            let from = max(point.date, start)
            let to = min(next, end)
            guard to > from else { continue }
            if let last = segments.last, last.level == level, last.end == from {
                segments[segments.count - 1] = Segment(start: last.start, end: to, level: level)
            } else {
                segments.append(Segment(start: from, end: to, level: level))
            }
        }
        self.segments = segments
    }

    /// Share of the covered time at each level, most severe first, e.g. [(.warning, 0.25), (.normal, 0.75)].
    var shares: [(level: MemoryPressureLevel, fraction: Double)] {
        let covered = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard covered > 0 else { return [] }
        return MemoryPressureLevel.allCases.reversed().compactMap { level in
            let time = segments.filter { $0.level == level }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            return time > 0 ? (level, time / covered) : nil
        }
    }

    /// VoiceOver value, e.g. "Normal 75%, Warning 25%".
    func summary(locale: Locale = .autoupdatingCurrent) -> String {
        let shares = shares
        guard !shares.isEmpty else { return L10n.string("No readings yet") }
        return shares.map { "\($0.level.title) \(MetricFormat.percent($0.fraction * 100, digits: 0, locale: locale))" }
            .joined(separator: ", ")
    }
}

/// One label / value row of the swap & paging section.
struct MemoryDetailRow: Equatable, Identifiable {
    let label: String
    let value: String
    let spoken: String

    var id: String { label }

    /// Swap usage first, then each paging rate that could be measured; rates whose
    /// counter went backwards are left out rather than shown as 0.
    static func paging(swap: SwapUsage?, rates: PagingRates?, locale: Locale = .autoupdatingCurrent) -> [MemoryDetailRow] {
        var rows: [MemoryDetailRow] = []
        if let swap {
            let label = L10n.string("Swap used")
            if swap.total == 0 {
                rows.append(MemoryDetailRow(label: label, value: L10n.string("Not in use"), spoken: L10n.string("Not in use")))
            } else {
                rows.append(MemoryDetailRow(
                    label: label,
                    value: "\(MemoryDetailFormat.bytes(swap.used, locale: locale)) / \(MemoryDetailFormat.bytes(swap.total, locale: locale))",
                    spoken: L10n.string("\(MemoryDetailFormat.spokenBytes(swap.used, locale: locale)), total \(MemoryDetailFormat.spokenBytes(swap.total, locale: locale))")))
            }
        }
        guard let rates else { return rows }
        let items: [(String, Double?)] = [
            (L10n.string("Page-ins"), rates.pageIns),
            (L10n.string("Page-outs"), rates.pageOuts),
            (L10n.string("Swap-ins"), rates.swapIns),
            (L10n.string("Swap-outs"), rates.swapOuts),
            (L10n.string("Compressions"), rates.compressions),
            (L10n.string("Decompressions"), rates.decompressions),
        ]
        for (label, rate) in items {
            guard let rate else { continue }
            rows.append(MemoryDetailRow(label: label, value: ByteRate.short(rate, locale: locale),
                                        spoken: ByteRate.spoken(rate, locale: locale)))
        }
        return rows
    }

    /// Installed memory and page size; each hidden when unknown.
    static func about(_ detail: MemoryDetail?, locale: Locale = .autoupdatingCurrent) -> [MemoryDetailRow] {
        var rows: [MemoryDetailRow] = []
        if let physical = detail?.physicalMemory {
            rows.append(MemoryDetailRow(label: L10n.string("Physical memory"),
                                        value: MemoryDetailFormat.installed(physical, locale: locale),
                                        spoken: MemoryDetailFormat.spokenInstalled(physical, locale: locale)))
        }
        if let pageSize = detail?.pageSize {
            rows.append(MemoryDetailRow(label: L10n.string("Page size"),
                                        value: MemoryDetailFormat.bytes(pageSize, locale: locale),
                                        spoken: MemoryDetailFormat.spokenBytes(pageSize, locale: locale)))
        }
        return rows
    }
}
