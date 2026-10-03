import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The CPU card's page (#25): usage split and history, per-core load, load average,
/// the busiest processes and facts about the chip. History comes from the engine;
/// everything else from samplers that run only while the page is on screen.
struct CPUDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = CPUDetailModel()
    @State private var range = HistoryRange.default

    var body: some View {
        DetailPage(metric: .cpu, range: $range) {
            CPUUsageSection(history: stats.history, range: range)
            CPUCoresSection(info: model.info, cores: model.reading?.cores)
            if let load = model.reading?.loadAverage {
                CPULoadSection(load: load, cores: model.info.logicalCores)
            }
            CPUTopProcessesSection(report: model.processes)
            CPUAboutSection(info: model.info, thermalState: model.reading?.thermalState)
        }
        .onAppear { model.start(engine: stats) }
        .onDisappear { model.stop() }
    }
}

/// Owns the page's samplers so they live exactly as long as the page. Main thread only:
/// both samplers deliver on the main queue.
final class CPUDetailModel: ObservableObject {
    /// Read once per visit; none of it changes while the Mac is running.
    let info = CPUInfo.read()
    @Published private(set) var reading: CPUDetailReading?
    @Published private(set) var processes: ProcessReport?

    private let detailSampler = CPUDetailSampler()
    private let processSampler = ProcessSampler()

    /// The bars follow the refresh rate the user picked, but never slower than every
    /// 2 s: a page someone is looking at should move.
    /// Readings reach the page with the engine's ticks (`StatsEngine.coalesce`).
    func start(engine: StatsEngine) {
        let interval = min(AppSettings.shared.updateInterval, 2)
        detailSampler.start(interval: interval) { [weak self] reading in
            engine.coalesce { self?.receive(reading) }
        }
        processSampler.start(interval: 2) { [weak self] report in
            engine.coalesce { self?.processes = report }
        }
    }

    private func receive(_ reading: CPUDetailReading) {
        var next = reading
        // A failed per-core read keeps the last bars rather than blanking them.
        if next.cores == nil { next.cores = self.reading?.cores }
        if next != self.reading { self.reading = next }
    }

    func stop() {
        detailSampler.stop()
        processSampler.stop()
    }
}

// MARK: - Usage

private struct CPUUsageSection: View {
    /// Observed so each engine tick redraws the headline and chart.
    @ObservedObject var history: MetricHistory
    let range: HistoryRange

    @Environment(\.locale) private var locale

    var body: some View {
        DetailSection(L10n.string("Usage")) {
            if let headline = latestHeadline {
                CPUHeadlineView(headline: headline)
            }
            MetricChart(title: L10n.string("CPU Usage"),
                        series: [MetricSeriesID.cpuUser, MetricSeriesID.cpuSystem].compactMap {
                            history.series($0, range: range)
                        },
                        labels: [MetricSeriesID.cpuUser: L10n.string("User"),
                                 MetricSeriesID.cpuSystem: L10n.string("System")],
                        style: .stackedArea,
                        range: range,
                        height: 110)
            SeriesStatsRow(statistics: history.statistics(MetricSeriesID.cpuTotal, range: range),
                           unit: .percent,
                           title: L10n.string("Total"))
        }
    }

    /// The newest engine reading, when the newest point of each series is a value.
    private var latestHeadline: CPUDetailPresentation.Headline? {
        func latest(_ id: String) -> Double? {
            history.series(id, range: .oneMinute)?.points.last?.value
        }
        return CPUDetailPresentation.headline(total: latest(MetricSeriesID.cpuTotal),
                                              user: latest(MetricSeriesID.cpuUser),
                                              system: latest(MetricSeriesID.cpuSystem))
    }
}

/// Total in large type, then a user / system / idle bar with its legend.
private struct CPUHeadlineView: View {
    let headline: CPUDetailPresentation.Headline

    @Environment(\.locale) private var locale

    private struct Part: Identifiable {
        let label: String
        let value: Double
        let color: Color

        var id: String { label }
    }

    private var parts: [Part] {
        [Part(label: L10n.string("User"), value: headline.user, color: ChartPalette.color(0)),
         Part(label: L10n.string("System"), value: headline.system, color: ChartPalette.color(1)),
         Part(label: L10n.string("Idle"), value: headline.idle, color: Color.secondary.opacity(0.25))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CPUDetailPresentation.percent(headline.total, locale: locale))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel(L10n.string("Total"))
                .accessibilityValue(CPUDetailPresentation.spokenPercent(headline.total, locale: locale))

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(parts, id: \.label) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: geometry.size.width * part.value / 100)
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                ForEach(parts, id: \.label) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text(part.label).foregroundStyle(.secondary)
                        Text(CPUDetailPresentation.percent(part.value, locale: locale)).monospacedDigit()
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(part.label)
                    .accessibilityValue(CPUDetailPresentation.spokenPercent(part.value, locale: locale))
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Cores

private struct CPUCoresSection: View {
    let info: CPUInfo
    let cores: [CPUSample?]?

    var body: some View {
        DetailSection(L10n.string("Cores")) {
            if let cores, !cores.isEmpty {
                ForEach(CPUDetailPresentation.coreGroups(info.groups, coreCount: cores.count)) { group in
                    CPUCoreGroupView(group: group, cores: cores)
                }
            } else {
                Text(L10n.string("Collecting data…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One perf level: its name and average, then a bar per logical core.
private struct CPUCoreGroupView: View {
    let group: CPUCoreGroup
    let cores: [CPUSample?]

    @Environment(\.locale) private var locale

    var body: some View {
        let spoken = CPUDetailPresentation.spokenGroup(group, cores: cores, locale: locale)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(CPUDetailPresentation.title(of: group))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let average = CPUDetailPresentation.average(of: group, in: cores) {
                    Text(CPUDetailPresentation.percent(average, digits: 0, locale: locale))
                        .monospacedDigit()
                }
            }
            .font(.caption)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(group.cores), id: \.self) { index in
                    CPUCoreBar(load: cores.indices.contains(index) ? cores[index] : nil)
                        .help(CPUDetailPresentation.spokenCore(index, load: cores.indices.contains(index)
                                                                   ? cores[index] : nil, locale: locale))
                }
            }
            .frame(height: 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.label)
        .accessibilityValue(spoken.value)
    }
}

/// A vertical track filled to the core's load: user and system stacked like the chart.
private struct CPUCoreBar: View {
    let load: CPUSample?

    var body: some View {
        // Core Animation eases the fills; a SwiftUI animation here redrew the
        // whole page on every frame (#35).
        AnimatedBar(direction: .up, segments: segments, cornerRadius: 2)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .frame(maxWidth: 18)
    }

    /// User at the bottom, system above it.
    private var segments: [AnimatedBar.Segment] {
        guard let load else { return [] }
        let system = min(load.system, 100)
        let user = max(min(load.total, 100) - system, 0)
        return [AnimatedBar.Segment(fraction: user / 100, color: ChartPalette.nsColor(0)),
                AnimatedBar.Segment(fraction: system / 100, color: ChartPalette.nsColor(1))]
    }
}

// MARK: - Load average

private struct CPULoadSection: View {
    let load: CPULoadAverage
    let cores: Int

    @Environment(\.locale) private var locale

    var body: some View {
        DetailSection(L10n.string("Load Average")) {
            HStack(spacing: 0) {
                ForEach(CPUDetailPresentation.loadColumns(load, locale: locale)) { column in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(column.value)
                            .font(.body.weight(.medium))
                            .monospacedDigit()
                        Text(column.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(column.spokenLabel)
                    .accessibilityValue(column.value)
                }
            }
            if cores > 0 {
                Text(CPUDetailPresentation.loadContext(cores: cores))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Top processes

private struct CPUTopProcessesSection: View {
    let report: ProcessReport?

    @Environment(\.locale) private var locale

    /// Shared generic icon for processes that are not apps.
    private static let executableIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    var body: some View {
        let rows = report?.top(.cpu, count: 5) ?? []
        DetailSection(L10n.string("Top Processes")) {
            if rows.isEmpty {
                Text(L10n.string("Collecting data…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { usage in
                    let value = CPUDetailPresentation.processValue(usage, locale: locale)
                    HStack(spacing: 6) {
                        Image(nsImage: usage.icon ?? Self.executableIcon)
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(usage.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(value.text)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(value.spoken)
                }
            }
            if let report, report.skippedCount > 0 {
                Text(L10n.string("Showing processes you can inspect"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

private struct CPUAboutSection: View {
    let info: CPUInfo
    let thermalState: ProcessInfo.ThermalState?

    var body: some View {
        DetailSection(L10n.string("About This CPU")) {
            if let chip = info.chipName {
                row(L10n.string("Chip"), chip)
            }
            ForEach(info.groups) { group in
                row(CPUDetailPresentation.title(of: group), String(group.cores.count))
            }
            if let boot = info.bootTime, let uptime = CPUDetailPresentation.uptime(Date().timeIntervalSince(boot)) {
                row(L10n.string("Uptime"), uptime.text, spoken: uptime.spoken)
            }
            if let level = thermalState.flatMap(CPUDetailPresentation.ThermalLevel.init) {
                HStack {
                    Text(L10n.string("Thermal state")).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(level.text)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(level.color.opacity(0.25), in: Capsule())
                        .overlay(Capsule().strokeBorder(level.color.opacity(0.7)))
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("Thermal state"))
                .accessibilityValue(level.text)
            }
        }
    }

    private func row(_ label: String, _ value: String, spoken: String? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken ?? value)
    }
}
