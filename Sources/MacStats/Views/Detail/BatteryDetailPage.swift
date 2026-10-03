import AppKit
import Charts
import SwiftUI

/// The Battery card's page (#28): charge, state and time left, the charge and battery
/// power history, the power adapter, battery health and Low Power Mode. Macs without a
/// battery get the power source and adapter only.
///
/// Charge history is the engine's `battery.level`; everything else comes from
/// `BatteryDetailSampler`, which runs only while the page is visible. Optimized and
/// limited charging are left out: macOS exposes them only through private interfaces.
struct BatteryDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = BatteryDetailModel()
    @State private var range = HistoryRange.default

    @Environment(\.locale) private var locale

    var body: some View {
        // Until the first reading, assume a battery when the card shows one, so the
        // layout does not jump on laptops.
        let hasBattery = model.detail.map { $0.battery != nil } ?? stats.snapshot.isBatteryAvailable
        DetailPage(metric: .battery, range: hasBattery ? $range : nil) {
            if hasBattery {
                if let battery = model.detail?.battery {
                    BatteryHeadline(battery: battery, locale: locale)
                }
                BatteryHistorySections(history: stats.history, range: range)
            } else {
                DetailUnavailableView(title: L10n.string("This Mac has no battery"),
                                      reason: L10n.string("Its power source is shown below."),
                                      icon: "powerplug")
            }
            if let detail = model.detail {
                power(detail)
                if let battery = detail.battery {
                    health(battery)
                }
            }
            modes
        }
        .onAppear { model.start(history: stats.history) }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private func power(_ detail: BatteryDetail) -> some View {
        let rows = BatteryDetailRow.power(detail, locale: locale)
        if !rows.isEmpty {
            DetailSection(detail.battery == nil ? L10n.string("Power") : L10n.string("Power adapter")) {
                BatteryRows(rows: rows)
            }
        }
    }

    @ViewBuilder
    private func health(_ battery: BatteryDetail.Battery) -> some View {
        let rows = BatteryDetailRow.health(battery, locale: locale)
        if !rows.isEmpty {
            DetailSection(L10n.string("Battery health")) {
                BatteryRows(rows: rows)
                if battery.health != nil {
                    BatteryFootnote(text: L10n.string("Health is maximum over design capacity. System Settings shows a smoothed figure that can differ by a few points."))
                }
            }
        }
    }

    private var modes: some View {
        let value = model.isLowPowerModeEnabled ? L10n.string("On") : L10n.string("Off")
        return DetailSection(L10n.string("Modes")) {
            BatteryRows(rows: [BatteryDetailRow(label: L10n.string("Low Power Mode"), value: value)])
        }
    }
}

/// Owns the page's sampler and Low Power Mode observer, which run only while the page is visible.
final class BatteryDetailModel: ObservableObject {
    @Published private(set) var detail: BatteryDetail?
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private let sampler: BatteryDetailSampler
    private var powerStateObserver: NSObjectProtocol?

    init(sampler: BatteryDetailSampler = BatteryDetailSampler()) {
        self.sampler = sampler
    }

    deinit {
        stop()
    }

    /// Main thread. On a Mac with a battery each reading's power and state go into
    /// history, so the charts keep what was seen on earlier visits too.
    func start(history: MetricHistory) {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        if powerStateObserver == nil {
            powerStateObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        sampler.start { [weak self, weak history] detail in
            guard let self else { return }
            if self.detail != detail { self.detail = detail }
            guard let battery = detail.battery, let history else { return }
            Self.record(battery, into: history)
        }
    }

    func stop() {
        sampler.stop()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
    }

    /// The page's two series; a reading without a state or power leaves its series untouched.
    static func record(_ battery: BatteryDetail.Battery, into history: MetricHistory) {
        let interval = BatteryDetailSampler.defaultInterval
        if let state = battery.state {
            history.register(BatteryDetailSeries.state, unit: .count, interval: interval)
            history.record(state.powerState.historyValue, for: BatteryDetailSeries.state, unit: .count)
        }
        if let watts = battery.watts {
            history.register(BatteryDetailSeries.watts, unit: .watts, interval: interval)
            history.record(watts, for: BatteryDetailSeries.watts, unit: .watts)
        }
    }
}

// MARK: - Headline

private struct BatteryHeadline: View {
    let battery: BatteryDetail.Battery
    let locale: Locale

    var body: some View {
        let state = BatteryDetailFormat.stateTitle(battery.state, locale: locale)
        let level = MetricFormat.percent(Double(battery.level), digits: 0, locale: locale)
        HStack(alignment: .top, spacing: 12) {
            HeadlineValue(title: state, value: level,
                          icon: StatCardFactory.batteryIcon(state: battery.state?.engineState ?? "Unknown",
                                                            level: battery.level),
                          spoken: "\(state), \(L10n.string("\(String(battery.level)) percent"))")
            if let time = battery.timeRemaining {
                let duration = BatteryDetailFormat.duration(minutes: time.minutes)
                let title = BatteryDetailFormat.timeTitle(time)
                HeadlineValue(title: title, value: duration.text, spoken: "\(title), \(duration.spoken)")
            }
            if let watts = battery.watts {
                let title = L10n.string("Power")
                HeadlineValue(title: title, value: BatteryDetailFormat.signedWatts(watts, locale: locale),
                              spoken: "\(title), \(BatteryDetailFormat.spokenWatts(watts, locale: locale))")
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct HeadlineValue: View {
    let title: String
    let value: String
    var icon: String? = nil
    let spoken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

// MARK: - Charts

/// The two history charts. A separate view so it alone observes the history's
/// revision; the rest of the page redraws on the sampler's readings.
private struct BatteryHistorySections: View {
    @ObservedObject var history: MetricHistory
    let range: HistoryRange

    @Environment(\.locale) private var locale

    var body: some View {
        // One right edge for every chart and the band, so they line up.
        let now = Date()
        let level = history.series(MetricSeriesID.batteryLevel, range: range, now: now)
        let states = history.series(BatteryDetailSeries.state, range: range, maxPoints: .max, now: now)
        let band = BatteryStateBand(points: states?.points ?? [], range: range, end: now,
                                    interval: BatteryDetailSampler.defaultInterval)
        let power = BatteryPowerSplit(history.series(BatteryDetailSeries.watts, range: range, now: now))
        // Raw readings for the stats rows; the chart's points are downsampled.
        let rawPower = BatteryPowerSplit(history.series(BatteryDetailSeries.watts, range: range, maxPoints: .max, now: now))
        let charging = BatteryDetailFormat.powerStateTitle(.charging, locale: locale)
        let discharging = BatteryDetailFormat.powerStateTitle(.onBattery, locale: locale)

        DetailSection(L10n.string("Battery Level")) {
            MetricChart(title: L10n.string("Battery Level"),
                        series: level.map { [$0] } ?? [],
                        labels: [MetricSeriesID.batteryLevel: L10n.string("Battery")],
                        style: .area, range: range, end: now, height: 100)
            BatteryStateBandView(band: band)
            SeriesStatsRow(statistics: history.statistics(MetricSeriesID.batteryLevel, range: range, now: now),
                           unit: .percent)
        }
        DetailSection(L10n.string("Battery power")) {
            MetricChart(title: L10n.string("Battery power"),
                        series: power.drawn,
                        labels: [BatteryPowerSplit.chargingID: charging, BatteryPowerSplit.dischargingID: discharging],
                        style: .line, range: range, end: now, height: 90)
            if let stats = BatteryPowerSplit.statistics(rawPower.charging) {
                SeriesStatsRow(statistics: stats, unit: .watts, title: charging)
            }
            if let stats = BatteryPowerSplit.statistics(rawPower.discharging) {
                SeriesStatsRow(statistics: stats, unit: .watts, title: discharging)
            }
            BatteryFootnote(text: L10n.string("Voltage × current at the battery. The power chart and the band are recorded while this page is open."))
        }
    }
}

/// A strip of power states on the same time axis as the charge chart above it.
private struct BatteryStateBandView: View {
    let band: BatteryStateBand

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(band.segments) { segment in
                RectangleMark(xStart: .value("Start", segment.start),
                              xEnd: .value("End", segment.end),
                              yStart: .value("Low", 0),
                              yEnd: .value("High", 1))
                    .foregroundStyle(segment.state.color)
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
                ForEach(BatteryPowerState.allCases.reversed(), id: \.self) { state in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(state.color)
                            .frame(width: 10, height: 8)
                        Text(BatteryDetailFormat.powerStateTitle(state, locale: locale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .font(.caption2)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Power source"))
        .accessibilityValue(band.summary(locale: locale))
    }
}

extension BatteryPowerState {
    /// Green / blue-gray / amber, each with a light and a dark variant that keeps at
    /// least 3:1 contrast against the popover. The legend names every color.
    var color: Color {
        let (light, dark): (ChartPalette.RGB, ChartPalette.RGB)
        switch self {
        case .charging: (light, dark) = (.init(red: 0x1A, green: 0x7F, blue: 0x37), .init(red: 0x3F, green: 0xB9, blue: 0x50))
        case .pluggedIn: (light, dark) = (.init(red: 0x57, green: 0x60, blue: 0x6A), .init(red: 0x8B, green: 0x94, blue: 0x9E))
        case .onBattery: (light, dark) = (.init(red: 0x9A, green: 0x67, blue: 0x00), .init(red: 0xD2, green: 0x99, blue: 0x22))
        }
        let lightColor = light.nsColor, darkColor = dark.nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

// MARK: - Rows

private struct BatteryRows: View {
    let rows: [BatteryDetailRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(row.value)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label), \(row.spoken)")
            }
        }
        .font(.caption)
    }
}

private struct BatteryFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
