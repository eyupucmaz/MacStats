import AppKit
import Charts
import SwiftUI

/// The RAM card's detail page (#27): used memory and pressure over time, the
/// Activity Monitor breakdown, swap and paging rates, the heaviest processes, and
/// the machine's memory size.
struct MemoryDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = MemoryDetailModel()
    @State private var range = HistoryRange.default

    @Environment(\.locale) private var locale

    var body: some View {
        DetailPage(metric: .ram, range: $range) {
            MemoryHeadline(used: stats.snapshot.memoryUsed, total: stats.snapshot.memoryTotal,
                           level: model.detail?.level)
            MemoryHistorySections(history: stats.history, range: range)
            breakdown
            paging
            MemoryTopProcesses(report: model.processes, locale: locale)
            about
        }
        .onAppear { model.start(history: stats.history) }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var breakdown: some View {
        DetailSection(L10n.string("Breakdown")) {
            if let breakdown = model.detail?.breakdown {
                MemoryBreakdownView(breakdown: breakdown, locale: locale)
            } else if model.detail != nil {
                DetailUnavailableView(reason: L10n.string("macOS did not report memory statistics."))
            } else {
                MemoryCollectingText()
            }
        }
    }

    @ViewBuilder
    private var paging: some View {
        let rows = MemoryDetailRow.paging(swap: model.detail?.swap, rates: model.detail?.rates, locale: locale)
        DetailSection(L10n.string("Swap & paging")) {
            MemoryRows(rows: rows)
            // Rates need a second sample, one interval after the page opens.
            if model.detail?.rates == nil {
                MemoryCollectingText()
            }
        }
    }

    @ViewBuilder
    private var about: some View {
        let rows = MemoryDetailRow.about(model.detail, locale: locale)
        if !rows.isEmpty {
            DetailSection(L10n.string("About")) {
                MemoryRows(rows: rows)
            }
        }
    }
}

/// Owns the page's two detail-only samplers, which run only while the page is visible.
final class MemoryDetailModel: ObservableObject {
    @Published private(set) var detail: MemoryDetail?
    @Published private(set) var processes: ProcessReport?

    private let sampler: MemoryDetailSampler
    private let processSampler: ProcessSampler

    init(sampler: MemoryDetailSampler = MemoryDetailSampler(), processSampler: ProcessSampler = ProcessSampler()) {
        self.sampler = sampler
        self.processSampler = processSampler
    }

    deinit {
        stop()
    }

    /// Main thread. Each reading's pressure level goes into history so the band
    /// under the pressure chart keeps what was seen on earlier visits too.
    func start(history: MetricHistory) {
        history.register(MemoryDetailSeries.pressureLevel, unit: .count, interval: MemoryDetailSampler.defaultInterval)
        sampler.start { [weak self, weak history] detail in
            self?.detail = detail
            if let level = detail.level {
                history?.record(level.severity, for: MemoryDetailSeries.pressureLevel, unit: .count)
            }
        }
        processSampler.start { [weak self] report in
            self?.processes = report
        }
    }

    func stop() {
        sampler.stop()
        processSampler.stop()
    }
}

// MARK: - Headline

private struct MemoryHeadline: View {
    let used: UInt64
    let total: UInt64
    let level: MemoryPressureLevel?

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if total > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Used"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MemorySize.usedOfTotal(used, total, locale: locale))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MemorySize.spoken(used: used, total: total, locale: locale))
            }
            Spacer(minLength: 8)
            if let level {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L10n.string("Memory pressure"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(level.color)
                            .frame(width: 9, height: 9)
                        Text(level.title)
                            .font(.title3.weight(.semibold))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(L10n.string("Memory pressure")), \(level.title)")
            }
        }
        .padding(.horizontal, 8)
    }
}

extension MemoryPressureLevel {
    /// Green / amber / red, each with a light and a dark variant that keeps at least
    /// 3:1 contrast against the popover (the same bar `ChartPalette` meets). Every
    /// use also carries the level's name, so color is never the only cue.
    var color: Color {
        let (light, dark): (ChartPalette.RGB, ChartPalette.RGB)
        switch self {
        case .normal: (light, dark) = (.init(red: 0x1A, green: 0x7F, blue: 0x37), .init(red: 0x3F, green: 0xB9, blue: 0x50))
        case .warning: (light, dark) = (.init(red: 0x9A, green: 0x67, blue: 0x00), .init(red: 0xD2, green: 0x99, blue: 0x22))
        case .critical: (light, dark) = (.init(red: 0xCF, green: 0x22, blue: 0x2E), .init(red: 0xF8, green: 0x51, blue: 0x49))
        }
        let lightColor = light.nsColor, darkColor = dark.nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

// MARK: - Charts

/// The two history charts. A separate view so it alone observes the history's
/// revision; the rest of the page redraws on the samplers' readings.
private struct MemoryHistorySections: View {
    @ObservedObject var history: MetricHistory
    let range: HistoryRange

    var body: some View {
        // One right edge for the pressure chart and its band, so they line up.
        let now = Date()
        let used = history.series(MetricSeriesID.memoryUsed, range: range, now: now)
        let pressure = history.series(MetricSeriesID.memoryPressure, range: range, now: now)
        let levels = history.series(MemoryDetailSeries.pressureLevel, range: range, now: now)
        let band = MemoryPressureBand(points: levels?.points ?? [], range: range, end: now,
                                      interval: MemoryDetailSampler.defaultInterval)

        DetailSection(L10n.string("Memory used")) {
            MetricChart(title: L10n.string("Memory used"),
                        series: used.map { [$0] } ?? [],
                        labels: [MetricSeriesID.memoryUsed: L10n.string("Used")],
                        style: .area, range: range, end: now, height: 110)
            SeriesStatsRow(statistics: history.statistics(MetricSeriesID.memoryUsed, range: range, now: now),
                           unit: .bytes)
        }
        DetailSection(L10n.string("Memory pressure")) {
            MetricChart(title: L10n.string("Memory pressure"),
                        series: pressure.map { [$0] } ?? [],
                        labels: [MetricSeriesID.memoryPressure: L10n.string("Pressure")],
                        style: .area, range: range, end: now, height: 90)
            MemoryPressureBandView(band: band)
            SeriesStatsRow(statistics: history.statistics(MetricSeriesID.memoryPressure, range: range, now: now),
                           unit: .percent)
            Text(L10n.string("The line is wired plus compressed memory as a share of RAM. The band is the level macOS reports, recorded while this page is open."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A strip of kernel pressure levels on the same time axis as the chart above it.
private struct MemoryPressureBandView: View {
    let band: MemoryPressureBand

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(band.segments) { segment in
                RectangleMark(xStart: .value("Start", segment.start),
                              xEnd: .value("End", segment.end),
                              yStart: .value("Low", 0),
                              yEnd: .value("High", 1))
                    .foregroundStyle(segment.level.color)
            }
            .chartXScale(domain: band.domain)
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            // An invisible copy of the chart's widest axis label ("100%") gives the
            // strip the same leading inset as the plot above, so times line up.
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.5]) { _ in
                    AxisValueLabel {
                        Text(MetricValueFormat.axis(100, unit: .percent, step: 25, locale: locale))
                            .hidden()
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.background(RoundedRectangle(cornerRadius: 2).fill(.quaternary.opacity(0.6)))
            }
            .frame(height: 10)

            HStack(spacing: 10) {
                ForEach(MemoryPressureLevel.allCases, id: \.self) { level in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level.color)
                            .frame(width: 10, height: 8)
                        Text(level.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption2)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Pressure level"))
        .accessibilityValue(band.summary(locale: locale))
    }
}

// MARK: - Breakdown

private struct MemoryBreakdownView: View {
    let breakdown: MemoryBreakdown
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(MemoryBreakdown.Category.allCases, id: \.self) { category in
                        let width = geometry.size.width * breakdown.fraction(category)
                        if width >= 0.5 {
                            Rectangle()
                                .fill(category.color)
                                .frame(width: max(width - 1, 0.5))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(.quaternary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            // The legend below reads every value; the bar adds nothing for VoiceOver.
            .accessibilityHidden(true)

            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                ForEach(MemoryBreakdown.Category.allCases, id: \.self) { category in
                    let bytes = breakdown.bytes(category)
                    GridRow {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color)
                            .frame(width: 10, height: 10)
                        Text(category.title)
                            .foregroundStyle(.secondary)
                        Text(MemoryDetailFormat.bytes(bytes, locale: locale))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(category.title), \(MemoryDetailFormat.spokenBytes(bytes, locale: locale))")
                }
            }
            .font(.caption)
        }
    }
}

extension MemoryBreakdown.Category {
    /// Chart palette colors, so they meet the same contrast bar; free memory is neutral.
    var color: Color {
        switch self {
        case .app: return ChartPalette.color(0)
        case .wired: return ChartPalette.color(1)
        case .compressed: return ChartPalette.color(3)
        case .cached: return ChartPalette.color(2)
        case .free: return Color.secondary.opacity(0.5)
        }
    }
}

// MARK: - Rows and processes

private struct MemoryRows: View {
    let rows: [MemoryDetailRow]

    var body: some View {
        if !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.label), \(row.spoken)")
                }
            }
            .font(.caption)
        }
    }
}

private struct MemoryCollectingText: View {
    var body: some View {
        Text(L10n.string("Collecting data…"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The five processes (apps with their helpers summed) with the largest memory footprint.
private struct MemoryTopProcesses: View {
    let report: ProcessReport?
    let locale: Locale

    var body: some View {
        DetailSection(L10n.string("Top processes")) {
            if let report {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.top(.memory, count: 5)) { process in
                        HStack(spacing: 6) {
                            icon(process)
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(process.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(MemoryDetailFormat.bytes(process.memoryBytes, locale: locale))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(process.name), \(MemoryDetailFormat.spokenBytes(process.memoryBytes, locale: locale))")
                    }
                    if report.skippedCount > 0 {
                        Text(L10n.string("Showing processes you can inspect"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                MemoryCollectingText()
            }
        }
    }

    @ViewBuilder
    private func icon(_ process: ProcessUsage) -> some View {
        if let image = process.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
        }
    }
}
