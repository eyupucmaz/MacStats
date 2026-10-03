import SwiftUI

/// The Fan card's page (#31): current speed, the RPM history of each fan, and every
/// fan's minimum, maximum and target speed with a "% of max" gauge.
///
/// The first fan's speed and history come from the engine (`fan.rpm`); the per-fan
/// details from `FanDetailReader`, sampled only while the page is visible. Everything
/// is read from the SMC; MacStats never sets fan speeds (docs/FAN_CONTROL.md).
struct FanDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = FanDetailModel()
    @State private var range = HistoryRange.default

    var body: some View {
        let report = model.report
        let isFanless = report?.isFanless == true
        // Until the first reading the card's value stands for a single fan.
        let fanCount = max(report?.fans.count ?? 0, 1)
        DetailPage(metric: .fan, range: isFanless ? nil : $range) {
            if isFanless {
                DetailSection(L10n.string("Fans")) {
                    DetailUnavailableView(title: L10n.string("No fan"),
                                          reason: L10n.string("This Mac is cooled passively."),
                                          icon: "fanblades")
                }
            } else {
                let cardRPM = stats.snapshot.isFanAvailable ? stats.snapshot.fanRPM : nil
                FanHeadline(items: FanDetailPresentation.headline(cardRPM: cardRPM, report: report),
                            fanCount: fanCount)
                FanHistorySection(history: stats.history, range: range, fanCount: fanCount)
                FanListSection(report: report)
            }
        }
        .onAppear { model.start(history: stats.history) }
        .onDisappear { model.stop() }
    }
}

/// Owns the page's sampler. Main thread only; the sampler reads on a utility queue.
///
/// Cost, measured by `FanDetailSamplerTests.testLiveReadAndSampleCost` on an Apple M5
/// MacBook Pro (one fan, five SMC reads per sample): about 0.06 ms of CPU per sample in
/// a debug build, i.e. about 0.006 % of one core at a 1 s interval.
final class FanDetailModel: ObservableObject {
    @Published private(set) var report: FanDetailReport?

    private let sampler: SMCDetailSampler<FanDetailReport>

    init(source: FanDetailSource = LiveFanDetailSource()) {
        sampler = SMCDetailSampler(label: "com.macstats.FanDetailSampler") {
            FanDetailReader.read(from: source)
        }
    }

    deinit {
        sampler.stop()
    }

    /// Follows the refresh rate the user picked, but never slower than every 2 s.
    /// A second fan's speed goes into history so its line keeps earlier visits too.
    func start(history: MetricHistory) {
        let interval = min(AppSettings.shared.updateInterval, 2)
        sampler.start(interval: interval) { [weak self, weak history] report in
            guard let self else { return }
            if report != self.report { self.report = report }
            guard let history, let second = report.fans.first(where: { $0.index == 1 }),
                  let rpm = second.current else { return }
            history.register(FanDetailPresentation.secondFanSeries, unit: .rpm, interval: interval)
            history.record(Double(rpm), for: FanDetailPresentation.secondFanSeries, unit: .rpm)
        }
    }

    func stop() {
        sampler.stop()
    }
}

// MARK: - Headline

private struct FanHeadline: View {
    let items: [FanDetailPresentation.HeadlineItem]
    let fanCount: Int

    @Environment(\.locale) private var locale

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    let title = FanDetailPresentation.title(index: item.index, fanCount: fanCount)
                    let rpm = FanDetailPresentation.rpm(item.rpm, locale: locale)
                    HStack(spacing: 6) {
                        Image(systemName: "fanblades.fill")
                            .font(.title3)
                            .foregroundStyle(ChartPalette.color(item.index))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(rpm.text)
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(rpm.spoken)
                }
            }
        }
    }
}

// MARK: - Chart

/// Observes the history store, so only this section redraws on each tick.
private struct FanHistorySection: View {
    @ObservedObject var history: MetricHistory
    let range: HistoryRange
    let fanCount: Int

    var body: some View {
        let now = Date()
        let ids = FanDetailPresentation.seriesIDs(fanCount: fanCount)
        let labels = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, FanDetailPresentation.title(index: index, fanCount: fanCount))
        })
        DetailSection(L10n.string("Fan Speed")) {
            MetricChart(title: L10n.string("Fan Speed"),
                        series: ids.compactMap { history.series($0, range: range, now: now) },
                        labels: labels,
                        style: .line,
                        range: range,
                        end: now,
                        height: 110)
            ForEach(ids, id: \.self) { id in
                SeriesStatsRow(statistics: history.statistics(id, range: range, now: now),
                               unit: .rpm,
                               title: fanCount > 1 ? labels[id] : nil)
            }
            if fanCount > 1 {
                Text(L10n.string("Fan 2 is recorded while this page is open."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Fans

private struct FanListSection: View {
    let report: FanDetailReport?

    var body: some View {
        DetailSection(L10n.string("Fans")) {
            if let report {
                if report.fans.isEmpty {
                    DetailUnavailableView(reason: L10n.string("macOS did not report fan speeds."),
                                          icon: "fanblades")
                } else {
                    if let count = report.count {
                        FanRow(row: .init(label: L10n.string("Number of fans"),
                                          value: String(count), spoken: String(count)))
                    }
                    ForEach(report.fans) { fan in
                        Divider()
                        FanView(fan: fan, fanCount: report.fans.count)
                    }
                }
            } else {
                Text(L10n.string("Collecting data…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A fan's name and speed, a gauge of its speed against its maximum, then its limits.
private struct FanView: View {
    let fan: FanDetail
    let fanCount: Int

    @Environment(\.locale) private var locale

    var body: some View {
        let title = FanDetailPresentation.title(index: fan.index, fanCount: fanCount)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let current = fan.current {
                    Text(FanDetailPresentation.rpm(current, locale: locale).text)
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(fan.current.map { FanDetailPresentation.rpm($0, locale: locale).spoken } ?? "")
            .accessibilityAddTraits(.isHeader)

            if let fraction = fan.fractionOfMaximum,
               let share = FanDetailPresentation.shareOfMaximum(fan, locale: locale) {
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(ChartPalette.color(fan.index))
                            .frame(width: geometry.size.width * fraction)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: Capsule())
                    }
                    .frame(height: 6)
                    .animation(.easeOut(duration: 0.2), value: fraction)
                    Text(share.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("Speed"))
                .accessibilityValue(share.spoken)
            }

            ForEach(FanDetailPresentation.rows(fan, locale: locale)) { row in
                FanRow(row: row)
            }
        }
    }
}

private struct FanRow: View {
    let row: FanDetailPresentation.Row

    var body: some View {
        HStack {
            Text(row.label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(row.value).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(row.spoken)
    }
}
