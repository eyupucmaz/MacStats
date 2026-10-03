import SwiftUI

/// The GPU card's page (#26): utilization and its history (plus the renderer and tiler
/// split when the driver reports it), GPU memory, and each GPU's model, cores and Metal
/// name. The headline and the overall line come from the engine; everything else from
/// `GPUDetailSampler`, which runs only while the page is visible. Per-process GPU usage
/// is out of scope by design (#20): macOS has no public API for it.
struct GPUDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = GPUDetailModel()
    @State private var range = HistoryRange.default

    var body: some View {
        DetailPage(metric: .gpu, range: $range) {
            GPUUsageSection(history: stats.history, range: range,
                            usage: stats.snapshot.isGPUAvailable ? stats.snapshot.gpuUsage : nil,
                            report: model.report)
            if let report = model.report {
                GPUMemorySection(report: report)
                GPUAboutSection(report: report)
            }
            Text(L10n.string("Per-app GPU usage is not shown: macOS has no public API for it."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .onAppear { model.start(history: stats.history) }
        .onDisappear { model.stop() }
    }
}

/// Owns the page's sampler so it lives exactly as long as the page. Main thread only:
/// the sampler delivers on the main queue.
final class GPUDetailModel: ObservableObject {
    @Published private(set) var report: GPUDetailReport?

    private let sampler: GPUDetailSampler

    init(sampler: GPUDetailSampler = GPUDetailSampler()) {
        self.sampler = sampler
    }

    deinit {
        sampler.stop()
    }

    /// Follows the refresh rate the user picked, but never slower than every 2 s: a page
    /// someone is looking at should move. Renderer and tiler readings go into history.
    func start(history: MetricHistory) {
        let interval = GPUDetailSampler.period(min(AppSettings.shared.updateInterval, 2))
        sampler.start(interval: interval) { [weak self, weak history] report in
            guard let self else { return }
            if report != self.report { self.report = report }
            if let history { GPUDetailSeries.record(report, in: history, interval: interval) }
        }
    }

    func stop() {
        sampler.stop()
    }
}

// MARK: - Usage

private struct GPUUsageSection: View {
    /// Observed so each engine tick redraws the chart.
    @ObservedObject var history: MetricHistory
    let range: HistoryRange
    /// The card's value; nil when macOS reports no utilization.
    let usage: Double?
    let report: GPUDetailReport?

    @Environment(\.locale) private var locale

    var body: some View {
        DetailSection(L10n.string("Usage")) {
            if let usage {
                let series = [MetricSeriesID.gpuUtilization, GPUDetailSeries.renderer, GPUDetailSeries.tiler]
                    .compactMap { history.series($0, range: range) }
                GPUHeadlineView(usage: usage, split: split(colorsFrom: series.map(\.id)))
                MetricChart(title: L10n.string("GPU Usage"),
                            series: series,
                            labels: GPUDetailPresentation.chartLabels,
                            style: .line,
                            range: range,
                            height: 110)
                SeriesStatsRow(statistics: history.statistics(MetricSeriesID.gpuUtilization, range: range),
                               unit: .percent,
                               title: L10n.string("Overall"))
                if series.count > 1 {
                    caption(L10n.string("Renderer is the GPU's pixel work, tiler its geometry work."))
                    if let report, report.gpus.count > 1, let gpu = report.chartGPU {
                        let name = GPUDetailPresentation.name(of: gpu)
                        caption(L10n.string("Renderer and tiler: \(name)"))
                    }
                }
            } else {
                DetailUnavailableView(reason: L10n.string("macOS does not report GPU utilization for this Mac's graphics driver."))
            }
        }
    }

    /// Renderer and tiler now, colored like their chart lines.
    private func split(colorsFrom ids: [String]) -> [GPUHeadlineView.Part] {
        guard let statistics = report?.chartGPU?.statistics else { return [] }
        let labels = GPUDetailPresentation.chartLabels
        return [(GPUDetailSeries.renderer, statistics.renderer), (GPUDetailSeries.tiler, statistics.tiler)]
            .compactMap { id, value in
                guard let value, let label = labels[id] else { return nil }
                let index = ids.firstIndex(of: id) ?? 0
                return GPUHeadlineView.Part(label: label, value: value, color: ChartPalette.color(index))
            }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Overall utilization in large type, then the renderer / tiler values when known.
private struct GPUHeadlineView: View {
    struct Part {
        let label: String
        let value: Double
        let color: Color
    }

    let usage: Double
    let split: [Part]

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(GPUDetailPresentation.percent(usage, locale: locale))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel(L10n.string("GPU Usage"))
                .accessibilityValue(GPUDetailPresentation.spokenPercent(usage, locale: locale))
            Spacer(minLength: 8)
            ForEach(split, id: \.label) { part in
                HStack(spacing: 4) {
                    Circle().fill(part.color).frame(width: 7, height: 7)
                    Text(part.label).foregroundStyle(.secondary)
                    Text(GPUDetailPresentation.percent(part.value, digits: 0, locale: locale)).monospacedDigit()
                }
                .font(.caption)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(part.label)
                .accessibilityValue(GPUDetailPresentation.spokenPercent(part.value, locale: locale))
            }
        }
    }
}

// MARK: - Memory

private struct GPUMemorySection: View {
    let report: GPUDetailReport

    @Environment(\.locale) private var locale

    var body: some View {
        let blocks = report.gpus.compactMap { gpu -> (GPUDevice, [GPUDetailRow])? in
            let rows = GPUDetailPresentation.memoryRows(gpu.statistics, locale: locale)
            return rows.isEmpty ? nil : (gpu, rows)
        }
        let showsNote = GPUDetailPresentation.showsUnifiedMemoryNote(report)
        if !blocks.isEmpty || showsNote {
            DetailSection(L10n.string("GPU Memory")) {
                ForEach(blocks, id: \.0.id) { gpu, rows in
                    if report.gpus.count > 1 {
                        Text(GPUDetailPresentation.name(of: gpu))
                            .font(.caption.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    GPURows(rows: rows)
                }
                if showsNote {
                    Text(L10n.string("Apple silicon has unified memory: the GPU uses the same RAM as the CPU, so this is part of the memory on the RAM page, not separate video memory."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - About

private struct GPUAboutSection: View {
    let report: GPUDetailReport

    @Environment(\.locale) private var locale

    var body: some View {
        if report.gpus.count == 1, let gpu = report.gpus.first {
            let rows = GPUDetailPresentation.aboutRows(gpu, includeModel: true)
            if !rows.isEmpty {
                DetailSection(L10n.string("About This GPU")) {
                    GPURows(rows: rows)
                }
            }
        } else if report.gpus.count > 1 {
            DetailSection(L10n.string("GPUs")) {
                ForEach(Array(report.gpus.enumerated()), id: \.element.id) { index, gpu in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(GPUDetailPresentation.name(of: gpu))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(GPUDetailPresentation.utilization(of: gpu, locale: locale).text)
                                .font(.caption)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(GPUDetailPresentation.spokenGPU(gpu, locale: locale))
                        .accessibilityAddTraits(.isHeader)
                        GPURows(rows: GPUDetailPresentation.aboutRows(gpu, includeModel: false))
                    }
                }
            }
        }
    }
}

private struct GPURows: View {
    let rows: [GPUDetailRow]

    var body: some View {
        if !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
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
}
