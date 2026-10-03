import Foundation

/// The value (y) axis of a `MetricChart`: the domain it plots and the ticks it
/// labels. Percent is fixed at 0–100 so charts stay comparable; everything else
/// fits the data with "nice" 1-2-5 steps.
struct ChartValueScale: Equatable {
    let domain: ClosedRange<Double>
    let ticks: [Double]
    let step: Double

    /// About four intervals fit the popover's chart height without crowding.
    static let targetIntervals = 4.0

    /// `minimum`/`maximum` are over the plotted (for stacked areas: summed)
    /// values; nil when there is no data yet.
    static func make(unit: MetricUnit, minimum: Double?, maximum: Double?) -> ChartValueScale {
        if unit == .percent {
            return ChartValueScale(domain: 0...100, ticks: [0, 25, 50, 75, 100], step: 25)
        }
        let span = minimumSpan(for: unit)
        var low = 0.0
        var high = max(maximum ?? 0, 0)
        if floatsAboveZero(unit), let minimum, let maximum {
            // Temperatures and fan speeds sit far from zero; starting the axis at
            // zero would flatten every change into a straight line.
            low = max(minimum, 0)
            high = max(maximum, low)
            if high - low < span {
                let middle = (low + high) / 2
                low = max(middle - span / 2, 0)
                high = low + span
            }
        } else {
            high = max(high, span)
        }

        var step = niceStep((high - low) / targetIntervals)
        if unit == .count { step = max(step, 1) }
        let lower = (low / step).rounded(.down) * step
        var upper = (high / step).rounded(.up) * step
        if upper <= lower { upper = lower + step }
        let intervals = Int(((upper - lower) / step).rounded())
        let ticks = (0...intervals).map { lower + Double($0) * step }
        return ChartValueScale(domain: lower...upper, ticks: ticks, step: step)
    }

    /// The smallest step from the 1-2-5 series that is at least `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 1 }
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let fraction = raw / magnitude
        let nice: Double
        switch fraction {
        case ...1.000_001: nice = 1
        case ...2.000_001: nice = 2
        case ...5.000_001: nice = 5
        default: nice = 10
        }
        return nice * magnitude
    }

    /// The smallest range an axis shows, so an idle metric (0 B/s) still gets a
    /// readable scale instead of a degenerate one.
    static func minimumSpan(for unit: MetricUnit) -> Double {
        switch unit {
        case .percent: return 100
        case .bytes, .bytesPerSecond: return 1_000
        case .rpm: return 1_000
        case .celsius: return 10
        case .watts: return 1
        case .count: return 4
        }
    }

    private static func floatsAboveZero(_ unit: MetricUnit) -> Bool {
        unit == .celsius || unit == .rpm
    }
}

/// The time (x) axis: always the whole selected range ending at `end`, so a
/// chart that has just started collecting fills in from the right instead of
/// stretching a few seconds across the full width.
struct ChartTimeScale: Equatable {
    let domain: ClosedRange<Date>
    let ticks: [Date]
    /// One-minute charts label seconds; longer ranges label hours and minutes.
    let showsSeconds: Bool

    static func make(range: HistoryRange, end: Date) -> ChartTimeScale {
        let start = end.addingTimeInterval(-range.duration)
        let step = tickStep(for: range)
        // Ticks sit on whole multiples of the step ("14:05", "14:10"), not at
        // arbitrary offsets from `end`.
        var tick = (start.timeIntervalSince1970 / step).rounded(.up) * step
        var ticks: [Date] = []
        while tick <= end.timeIntervalSince1970 {
            ticks.append(Date(timeIntervalSince1970: tick))
            tick += step
        }
        return ChartTimeScale(domain: start...end, ticks: ticks, showsSeconds: range == .oneMinute)
    }

    /// Spaced so that three to five labels fit the popover's width.
    static func tickStep(for range: HistoryRange) -> TimeInterval {
        switch range {
        case .oneMinute: return 20
        case .fiveMinutes: return 120
        case .fifteenMinutes: return 300
        case .oneHour: return 900
        }
    }
}
