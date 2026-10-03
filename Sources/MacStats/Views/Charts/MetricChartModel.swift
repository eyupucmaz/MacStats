import Foundation

/// How a `MetricChart` draws its series.
enum MetricChartStyle: Equatable {
    /// One line per series.
    case line
    /// Lines with a translucent fill down to the axis; series overlap.
    case area
    /// Series stacked bottom-up in the order given (e.g. user + system CPU).
    case stackedArea
}

/// Everything `MetricChart` draws, computed once per data change and free of
/// SwiftUI so the gap, stacking, scale and hover logic can be unit tested.
///
/// Series of one chart share a unit (the first series' unit picks the axis).
/// The history store samples every metric on the same ticks, so series also
/// share timestamps; stacking and the hover tooltip match points by date.
struct MetricChartModel {
    /// The most series one chart shows; more would not be readable at popover size.
    static let maximumSeries = 4

    struct Series: Identifiable, Equatable {
        let id: String
        /// Position in the chart; picks the palette color and dash pattern.
        let index: Int
        let label: String
        let points: [MetricPoint]
        /// The newest non-gap point: marked at the right edge and shown in the legend.
        let latest: PlotPoint?
    }

    /// A drawable point. `value` is the series' own reading; `low`/`high` are
    /// where it is plotted (equal to 0…value except when stacked).
    struct PlotPoint: Equatable {
        let date: Date
        let value: Double
        let low: Double
        let high: Double
    }

    /// An unbroken run of points; a gap (nil value) ends one and starts the next,
    /// so no line is drawn across missing samples.
    struct Segment: Identifiable, Equatable {
        let id: String
        let seriesIndex: Int
        let points: [PlotPoint]
    }

    struct HoverEntry: Equatable {
        let seriesIndex: Int
        let label: String
        /// nil when the series has no reading at that time (a gap).
        let value: Double?
        /// Where the crosshair dot goes; the top of the band when stacked.
        let plotted: Double?
    }

    struct Hover: Equatable {
        let date: Date
        let entries: [HoverEntry]
    }

    let style: MetricChartStyle
    let unit: MetricUnit
    let range: HistoryRange
    let series: [Series]
    let segments: [Segment]
    let valueScale: ChartValueScale
    let timeScale: ChartTimeScale
    /// True until some series has two readings; the chart then shows "Collecting data…".
    let isEmpty: Bool

    /// Every sampled date across the series (gaps included), sorted.
    private let dates: [Date]
    /// Per series, the plotted point at each date that has a reading.
    private let plotted: [[Date: PlotPoint]]

    /// - Parameters:
    ///   - labels: Display name per series id; the id is shown when missing.
    ///   - end: Right edge of the time axis; defaults to the newest sample.
    init(series input: [MetricSeries],
         labels: [String: String] = [:],
         style: MetricChartStyle = .line,
         range: HistoryRange = .default,
         end: Date? = nil) {
        let input = Array(input.prefix(Self.maximumSeries))
        self.style = style
        self.range = range
        unit = input.first?.unit ?? .count

        let allDates = Set(input.flatMap { $0.points.map(\.date) }).sorted()
        dates = allDates
        let end = end ?? allDates.last ?? Date()
        timeScale = ChartTimeScale.make(range: range, end: end)

        // Plot positions before the scale exists: only the stacked tops matter
        // for the domain, and the area base is fixed up below.
        var plotted: [[Date: PlotPoint]] = []
        if style == .stackedArea {
            plotted = Self.stack(input, dates: allDates)
        } else {
            plotted = input.map { series in
                var points: [Date: PlotPoint] = [:]
                for point in series.points {
                    if let value = point.value {
                        points[point.date] = PlotPoint(date: point.date, value: value, low: 0, high: value)
                    }
                }
                return points
            }
        }
        let highs = plotted.flatMap { $0.values.map(\.high) }
        let lows = plotted.flatMap { $0.values.map(style == .stackedArea ? \.low : \.value) }
        valueScale = ChartValueScale.make(unit: unit, minimum: lows.min(), maximum: highs.max())

        // An unstacked area fills down to the bottom of the axis, which is not
        // zero for temperatures and fan speeds.
        if style == .area {
            let base = valueScale.domain.lowerBound
            plotted = plotted.map { points in
                points.mapValues { PlotPoint(date: $0.date, value: $0.value, low: base, high: $0.high) }
            }
        }
        self.plotted = plotted

        var segments: [Segment] = []
        var series: [Series] = []
        for (index, item) in input.enumerated() {
            // Stacked layers break wherever their own reading is missing.
            let points = style == .stackedArea
                ? allDates.map { MetricPoint(date: $0, value: plotted[index][$0]?.value) }
                : item.points
            for (number, run) in Self.segments(of: points).enumerated() {
                segments.append(Segment(id: "\(index)-\(number)", seriesIndex: index,
                                        points: run.compactMap { plotted[index][$0.date] }))
            }
            let latest = item.points.last(where: { $0.value != nil }).flatMap { plotted[index][$0.date] }
            series.append(Series(id: item.id, index: index, label: labels[item.id] ?? item.id,
                                 points: item.points, latest: latest))
        }
        self.segments = segments
        self.series = series
        isEmpty = !input.contains { $0.points.lazy.filter { $0.value != nil }.count >= 2 }
    }

    /// Splits a series at its gaps: every maximal run of non-nil points, in order.
    static func segments(of points: [MetricPoint]) -> [[MetricPoint]] {
        var runs: [[MetricPoint]] = []
        var current: [MetricPoint] = []
        for point in points {
            if point.value == nil {
                if !current.isEmpty { runs.append(current) }
                current = []
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Stacks the series bottom-up at each date. A series without a reading at
    /// a date contributes nothing there and its own band breaks.
    static func stack(_ series: [MetricSeries], dates: [Date]) -> [[Date: PlotPoint]] {
        let readings: [[Date: Double]] = series.map { item in
            var values: [Date: Double] = [:]
            for point in item.points { if let value = point.value { values[point.date] = value } }
            return values
        }
        var stacked = Array(repeating: [Date: PlotPoint](), count: series.count)
        for date in dates {
            var running = 0.0
            for index in series.indices {
                guard let value = readings[index][date] else { continue }
                let low = running
                running += max(value, 0)
                stacked[index][date] = PlotPoint(date: date, value: value, low: low, high: running)
            }
        }
        return stacked
    }

    /// The sample nearest to `date` (gaps included, so hovering a gap says so)
    /// with each series' reading there; nil when there is no data at all.
    func hover(at date: Date) -> Hover? {
        guard let nearest = Self.nearest(to: date, in: dates) else { return nil }
        let entries = series.map { series -> HoverEntry in
            let point = plotted[series.index][nearest]
            return HoverEntry(seriesIndex: series.index, label: series.label,
                              value: point?.value, plotted: point?.high)
        }
        return Hover(date: nearest, entries: entries)
    }

    /// Binary search over sorted dates; ties go to the earlier sample.
    static func nearest(to date: Date, in dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        var low = 0
        var high = dates.count - 1
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] < date { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return dates[low] }
        let before = dates[low - 1]
        let after = dates[low]
        return date.timeIntervalSince(before) <= after.timeIntervalSince(date) ? before : after
    }
}
