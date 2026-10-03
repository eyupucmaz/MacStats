import Charts
import SwiftUI

/// The chart every detail page uses (#23): 1–4 series of one unit over a
/// `HistoryRange`, drawn as lines, areas or stacked areas, with a legend that
/// shows each series' latest value, a hover crosshair and tooltip, and an
/// audio-graph descriptor for VoiceOver.
///
/// It draws what it is given: pass the series already cut to `range` and
/// downsampled by the history store; nil points are drawn as gaps.
///
///     MetricChart(title: cpuTitle,
///                 series: [user, system],
///                 labels: ["cpu.user": userLabel, "cpu.system": systemLabel],
///                 style: .stackedArea,
///                 range: range)
///
/// (Labels arrive localized; the chart translates none of them.)
struct MetricChart: View {
    /// Names the chart for VoiceOver and its audio graph.
    let title: String
    let series: [MetricSeries]
    /// Display name per series id (legend, tooltip, VoiceOver).
    var labels: [String: String] = [:]
    var style: MetricChartStyle = .line
    var range: HistoryRange = .default
    /// Right edge of the time axis; defaults to the newest sample.
    var end: Date? = nil
    var height: CGFloat = 130

    @Environment(\.locale) private var locale

    var body: some View {
        // Rebuilt only when the inputs change: hover state lives further down,
        // in `ChartHoverLayer`, so moving the pointer never redoes this work.
        let model = MetricChartModel(series: series, labels: labels, style: style, range: range, end: end)
        VStack(alignment: .leading, spacing: 6) {
            MetricChartLegend(model: model, locale: locale)
            if model.isEmpty {
                Text(L10n.string("Collecting data…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            } else {
                MetricChartPlot(title: title, model: model, locale: locale)
                    .frame(height: height)
            }
        }
    }
}

// MARK: - Plot

private struct MetricChartPlot: View {
    let title: String
    let model: MetricChartModel
    let locale: Locale

    var body: some View {
        let descriptor = MetricChartDescriptor(title: title, model: model, locale: locale)
        Chart {
            ForEach(model.segments) { segment in
                SegmentMarks(segment: segment, style: model.style)
            }
            ForEach(model.series) { series in
                if let latest = series.latest {
                    // The "now" reading, pinned where the line ends.
                    PointMark(x: .value("Time", latest.date), y: .value("Value", latest.high))
                        .symbolSize(30)
                        .foregroundStyle(ChartPalette.color(series.index))
                }
            }
        }
        .chartXScale(domain: model.timeScale.domain)
        .chartYScale(domain: model.valueScale.domain)
        .chartXAxis {
            AxisMarks(values: model.timeScale.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(MetricValueFormat.time(date, seconds: model.timeScale.showsSeconds, locale: locale))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: model.valueScale.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MetricValueFormat.axis(number, unit: model.unit, step: model.valueScale.step,
                                                    locale: locale))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            ChartHoverLayer(proxy: proxy, model: model, locale: locale)
        }
        // One element with an audio graph instead of one element per mark,
        // which would be hundreds of stops for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(descriptor.summary)
        .accessibilityChartDescriptor(descriptor)
    }
}

/// The marks of one unbroken run: fill (area styles), line, and a dot when the
/// run is a single sample a line could not show.
private struct SegmentMarks: ChartContent {
    let segment: MetricChartModel.Segment
    let style: MetricChartStyle

    var body: some ChartContent {
        let color = ChartPalette.color(segment.seriesIndex)
        if style != .line {
            ForEach(segment.points, id: \.date) { point in
                AreaMark(x: .value("Time", point.date),
                         yStart: .value("Low", point.low),
                         yEnd: .value("High", point.high),
                         series: .value("Segment", segment.id))
                    .foregroundStyle(color.opacity(style == .stackedArea ? 0.32 : 0.14))
            }
        }
        ForEach(segment.points, id: \.date) { point in
            LineMark(x: .value("Time", point.date),
                     y: .value("Value", point.high),
                     series: .value("Segment", segment.id))
                .foregroundStyle(color)
                .lineStyle(ChartPalette.stroke(segment.seriesIndex))
        }
        if segment.points.count == 1, let point = segment.points.first {
            PointMark(x: .value("Time", point.date), y: .value("Value", point.high))
                .symbolSize(12)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Hover

/// Crosshair, dots and tooltip under the pointer. Owns the hover state so that
/// pointer movement redraws only this layer, never the chart's marks.
private struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let model: MetricChartModel
    let locale: Locale

    @State private var location: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            let hover = hover(in: plot)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): location = point
                        case .ended: location = nil
                        }
                    }
                if let hover {
                    crosshair(hover, plot: plot, width: geometry.size.width)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover?.date)
        }
    }

    private func hover(in plot: CGRect) -> (date: Date, x: CGFloat, value: MetricChartModel.Hover)? {
        guard let location, location.x >= plot.minX, location.x <= plot.maxX,
              let date: Date = proxy.value(atX: location.x - plot.minX),
              let hover = model.hover(at: date),
              let x = proxy.position(forX: hover.date) else { return nil }
        return (hover.date, plot.minX + x, hover)
    }

    @ViewBuilder
    private func crosshair(_ hover: (date: Date, x: CGFloat, value: MetricChartModel.Hover),
                           plot: CGRect, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.7))
            .frame(width: 1, height: plot.height)
            .position(x: hover.x, y: plot.midY)
        ForEach(hover.value.entries, id: \.seriesIndex) { entry in
            if let plotted = entry.plotted, let y = proxy.position(forY: plotted) {
                Circle()
                    .fill(ChartPalette.color(entry.seriesIndex))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .position(x: hover.x, y: plot.minY + y)
            }
        }
        // Beside the crosshair, on whichever side has more room.
        let onLeft = hover.x > plot.midX
        ChartTooltip(hover: hover.value, unit: model.unit, locale: locale)
            .fixedSize()
            .frame(width: max(onLeft ? hover.x - 8 : width - hover.x - 8, 0),
                   alignment: onLeft ? .trailing : .leading)
            .offset(x: onLeft ? 0 : hover.x + 8, y: plot.minY + 2)
    }
}

private struct ChartTooltip: View {
    let hover: MetricChartModel.Hover
    let unit: MetricUnit
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MetricValueFormat.time(hover.date, locale: locale))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ForEach(hover.entries, id: \.seriesIndex) { entry in
                HStack(spacing: 5) {
                    SeriesSwatch(index: entry.seriesIndex)
                    Text(entry.label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(entry.value.map { MetricValueFormat.short($0, unit: unit, locale: locale) }
                         ?? MetricFormat.unavailable)
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        // Pointer-only; VoiceOver users get the same values from the audio graph.
        .accessibilityHidden(true)
    }
}

// MARK: - Legend

private struct MetricChartLegend: View {
    let model: MetricChartModel
    let locale: Locale

    var body: some View {
        // One row when it fits, otherwise two columns.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { items }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) { items }
        }
        .font(.caption)
    }

    private var items: some View {
        ForEach(model.series) { series in
            let latest = series.latest.map { MetricValueFormat.short($0.value, unit: model.unit, locale: locale) }
            let spoken = series.latest.map { MetricValueFormat.spoken($0.value, unit: model.unit, locale: locale) }
            HStack(spacing: 5) {
                SeriesSwatch(index: series.index)
                Text(series.label)
                    .foregroundStyle(.secondary)
                Text(latest ?? MetricFormat.unavailable)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken.map { "\(series.label), \($0)" } ?? series.label)
        }
    }
}

/// A short stroke in a series' color and dash pattern, for legend and tooltip.
struct SeriesSwatch: View {
    let index: Int

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 4))
            path.addLine(to: CGPoint(x: 16, y: 4))
        }
        .stroke(ChartPalette.color(index), style: ChartPalette.stroke(index, width: 2))
        .frame(width: 16, height: 8)
        .accessibilityHidden(true)
    }
}
