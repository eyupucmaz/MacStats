import Charts
import SwiftUI

/// The Temp card's page (#32): the card's CPU temperature and the thermal state, the
/// temperature history with thermal-state changes under it, and every SMC temperature
/// sensor mapped for this Mac's chip with its session low and high. Celsius only.
///
/// The headline and chart come from the engine (`temperature.primary`); the sensors from
/// `TemperatureSensorReader`, sampled only while the page is visible. Read-only SMC.
struct TemperatureDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = TemperatureDetailModel()
    @State private var range = HistoryRange.default

    var body: some View {
        DetailPage(metric: .temp, range: $range) {
            TemperatureHeadline(celsius: stats.snapshot.isTemperatureAvailable ? stats.snapshot.temperature : nil,
                                level: model.thermalState.flatMap(CPUDetailPresentation.ThermalLevel.init))
            TemperatureHistorySection(history: stats.history, range: range, timeline: model.timeline)
            TemperatureSensorsSection(report: model.report, session: model.session)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// Owns the page's sensor sampler and thermal-state observer, both active only while
/// the page is visible. Main thread only.
///
/// The session range and the thermal timeline outlive the model (static, in memory,
/// cleared on quit), so reopening the page keeps what earlier visits saw.
///
/// Cost, measured by `TemperatureDetailLiveTests.testLiveReadAndSampleCost` on an Apple
/// M5 MacBook Pro (58 mapped keys, 56 present): about 0.8 ms of CPU per sample in a
/// debug build, i.e. about 0.04 % of one core at the 2 s interval.
final class TemperatureDetailModel: ObservableObject {
    static let interval: TimeInterval = 2

    private static var sharedSession = TemperatureSessionRange()
    private static var sharedTimeline = ThermalStateTimeline()

    @Published private(set) var report: TemperatureDetailReport?
    @Published private(set) var session = TemperatureDetailModel.sharedSession
    @Published private(set) var timeline = TemperatureDetailModel.sharedTimeline
    @Published private(set) var thermalState: ProcessInfo.ThermalState?

    private let sampler: SMCDetailSampler<TemperatureDetailReport>
    private var observer: NSObjectProtocol?

    /// `family` nil (an unknown chip) leaves only the card's sensor.
    init(source: TemperatureSensorSource = LiveTemperatureSensorSource(),
         family: TemperatureChipFamily? = TemperatureChipFamily(
            chipName: LiveSysctlReader().string("machdep.cpu.brand_string"))) {
        let sensors = family.map(TemperatureSensorCatalog.sensors(for:)) ?? []
        sampler = SMCDetailSampler(label: "com.macstats.TemperatureDetailSampler") {
            TemperatureSensorReader.read(sensors, from: source)
        }
    }

    deinit {
        sampler.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        sampler.start(interval: Self.interval) { [weak self] report in
            guard let self else { return }
            Self.sharedSession.record(report.readings)
            if report != self.report { self.report = report }
            if Self.sharedSession != self.session { self.session = Self.sharedSession }
        }
        recordThermalState()
        guard observer == nil else { return }
        // Posted on an arbitrary thread; handled on main.
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.recordThermalState()
        }
    }

    func stop() {
        sampler.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        // What happens while the page is closed is not watched; the band shows a gap.
        Self.sharedTimeline.record(nil, at: Date())
        timeline = Self.sharedTimeline
    }

    private func recordThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        thermalState = state
        Self.sharedTimeline.record(state, at: Date())
        timeline = Self.sharedTimeline
    }
}

// MARK: - Headline

private struct TemperatureHeadline: View {
    let celsius: Double?
    let level: CPUDetailPresentation.ThermalLevel?

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let celsius {
                let value = TemperatureDetailPresentation.celsius(celsius, locale: locale)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("CPU"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value.text)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("CPU"))
                .accessibilityValue(value.spoken)
            }
            Spacer(minLength: 8)
            if let level {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L10n.string("Thermal state"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(level.color)
                            .frame(width: 9, height: 9)
                        Text(level.text)
                            .font(.title3.weight(.semibold))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("Thermal state"))
                .accessibilityValue(level.text)
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Chart

/// Observes the history store, so only this section redraws on each tick.
private struct TemperatureHistorySection: View {
    @ObservedObject var history: MetricHistory
    let range: HistoryRange
    let timeline: ThermalStateTimeline

    var body: some View {
        // One right edge for the chart and its band, so they line up.
        let now = Date()
        let id = MetricSeriesID.temperaturePrimary
        DetailSection(L10n.string("CPU temperature")) {
            MetricChart(title: L10n.string("CPU temperature"),
                        series: history.series(id, range: range, now: now).map { [$0] } ?? [],
                        labels: [id: L10n.string("CPU")],
                        style: .line, range: range, end: now, height: 110)
            ThermalStateBandView(band: ThermalStateBand(timeline: timeline, range: range, end: now))
            SeriesStatsRow(statistics: history.statistics(id, range: range, now: now), unit: .celsius)
            Text(L10n.string("The band is the thermal state macOS reports, recorded while this page is open."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A strip of thermal states on the same time axis as the chart above it.
private struct ThermalStateBandView: View {
    let band: ThermalStateBand

    @Environment(\.locale) private var locale

    private static let levels: [CPUDetailPresentation.ThermalLevel] = [.nominal, .fair, .serious, .critical]

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
            // An invisible copy of a wide axis label gives the strip the chart's
            // leading inset, so times line up.
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.5]) { _ in
                    AxisValueLabel {
                        Text(MetricValueFormat.axis(100, unit: .celsius, step: 5, locale: locale))
                            .hidden()
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.background(RoundedRectangle(cornerRadius: 2).fill(.quaternary.opacity(0.6)))
            }
            .frame(height: 10)

            HStack(spacing: 10) {
                ForEach(Self.levels, id: \.text) { level in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level.color)
                            .frame(width: 10, height: 8)
                        Text(level.text)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption2)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Thermal state"))
        .accessibilityValue(band.summary(locale: locale))
    }
}

// MARK: - Sensors

private struct TemperatureSensorsSection: View {
    let report: TemperatureDetailReport?
    let session: TemperatureSessionRange

    @State private var expanded: Set<TemperatureSensorGroup> = []
    @Environment(\.locale) private var locale

    var body: some View {
        DetailSection(L10n.string("Sensors")) {
            if let report {
                let groups = TemperatureDetailPresentation.groups(report, session: session, locale: locale)
                if !report.isMapped {
                    caption(L10n.string("Detailed sensors aren't mapped for this Mac yet."))
                }
                if groups.isEmpty {
                    DetailUnavailableView(reason: L10n.string("macOS did not report any temperature sensors."),
                                          icon: "thermometer.medium")
                } else {
                    TemperatureColumnHeader()
                    if report.isMapped {
                        ForEach(groups) { group in
                            TemperatureGroupView(group: group, isExpanded: expansion(of: group.group))
                        }
                        caption(L10n.string("Groups show their hottest sensor now and the range of all their sensors. Min and max are the lowest and highest readings since MacStats started, while this page was open."))
                    } else {
                        ForEach(groups.flatMap(\.rows)) { TemperatureSensorRowView(row: $0) }
                        caption(L10n.string("Min and max are the lowest and highest readings since MacStats started, while this page was open."))
                    }
                }
            } else {
                caption(L10n.string("Collecting data…"))
            }
        }
    }

    private func expansion(of group: TemperatureSensorGroup) -> Binding<Bool> {
        Binding(get: { expanded.contains(group) },
                set: { isOn in
                    if isOn { expanded.insert(group) } else { expanded.remove(group) }
                })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fixed trailing columns, so every row's values line up under the header.
private enum TemperatureColumns {
    static let width: CGFloat = 50
}

private struct TemperatureColumnHeader: View {
    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(L10n.string("Now")).frame(width: TemperatureColumns.width, alignment: .trailing)
            Text(L10n.string("Min")).frame(width: TemperatureColumns.width, alignment: .trailing)
            Text(L10n.string("Max")).frame(width: TemperatureColumns.width, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// A group's name, its hottest reading now and its session range; click to list its sensors.
private struct TemperatureGroupView: View {
    let group: TemperatureDetailPresentation.SensorGroup
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(group.title)
                        .lineLimit(1)
                    Text(String(group.rows.count))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Group {
                        Text(group.hottest)
                        Text(group.low).foregroundStyle(.secondary)
                        Text(group.high).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .frame(width: TemperatureColumns.width, alignment: .trailing)
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.spoken)
            .accessibilityValue(isExpanded ? L10n.string("Expanded") : L10n.string("Collapsed"))

            if isExpanded {
                ForEach(group.rows) { row in
                    TemperatureSensorRowView(row: row)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

private struct TemperatureSensorRowView: View {
    let row: TemperatureDetailPresentation.SensorRow

    var body: some View {
        HStack(spacing: 4) {
            Text(row.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(row.key)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Group {
                Text(row.now)
                Text(row.low).foregroundStyle(.secondary)
                Text(row.high).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: TemperatureColumns.width, alignment: .trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}
