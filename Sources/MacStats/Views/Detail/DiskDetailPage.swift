import SwiftUI

/// The Disk card's detail page (#29): the startup volume's capacity, every mounted
/// volume, read/write activity, the processes doing the most disk I/O, and the drive.
struct DiskDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = DiskDetailModel()
    @State private var range = HistoryRange.default
    @Environment(\.locale) private var locale

    var body: some View {
        DetailPage(metric: .disk, range: $range) {
            startupSection
            if !model.volumes.isEmpty {
                volumesSection
            }
            activitySection
            processesSection
            if let drive = model.drive {
                let rows = DiskDetailPresentation.aboutRows(drive)
                if !rows.isEmpty {
                    DetailSection(L10n.string("About")) { DiskDetailRows(rows: rows) }
                }
            }
        }
        .onAppear { model.start(engine: stats) }
        .onDisappear { model.stop() }
    }

    // MARK: Startup disk

    @ViewBuilder
    private var startupSection: some View {
        DetailSection(L10n.string("Startup Disk")) {
            if let headline = DiskDetailPresentation.headline(stats.snapshot, locale: locale) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline.percentUsed)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(headline.freeOfTotal)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headline.accessibility)

                let segments = model.startup.map(DiskDetailPresentation.segments)
                    ?? .init(used: headline.usedFraction, purgeable: 0, available: 1 - headline.usedFraction)
                DiskCapacityBar(segments: segments)
                if let startup = model.startup {
                    DiskDetailRows(rows: DiskDetailPresentation.capacityRows(startup, locale: locale))
                }
            } else {
                DetailUnavailableView(reason: L10n.string("macOS did not report the startup disk's capacity."),
                                      icon: "internaldrive")
            }
        }
    }

    // MARK: Volumes

    private var volumesSection: some View {
        DetailSection(L10n.string("All Volumes")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.volumes) { volume in
                    DiskVolumeRow(volume: volume)
                }
            }
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activitySection: some View {
        DetailSection(L10n.string("Disk Activity")) {
            if model.isActivityUnavailable {
                DetailUnavailableView(reason: L10n.string("macOS does not report read and write activity for this Mac's drives."),
                                      icon: "internaldrive")
            } else {
                DiskActivityChart(history: stats.history, range: range)
                if let activity = model.activity {
                    DiskDetailRows(rows: DiskDetailPresentation.activityRows(activity, locale: locale))
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Processes

    @ViewBuilder
    private var processesSection: some View {
        DetailSection(L10n.string("Processes by Disk I/O")) {
            if let report = model.processes {
                let top = DiskDetailPresentation.topProcesses(report)
                if top.isEmpty {
                    Text(L10n.string("No process is reading or writing right now."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(top) { process in
                            DiskProcessRow(process: process)
                        }
                    }
                }
                if report.skippedCount > 0 {
                    Text(L10n.string("Disk I/O is shown only for processes MacStats can inspect."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.string("Collecting data…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pieces

/// Read and write throughput over the selected range, with min / avg / max per series.
/// Observes the history itself so the chart redraws when the page records a sample.
private struct DiskActivityChart: View {
    @ObservedObject var history: MetricHistory
    let range: HistoryRange

    var body: some View {
        let ids = [DiskDetailModel.readSeries, DiskDetailModel.writeSeries]
        let read = DiskDetailPresentation.readLabel
        let write = DiskDetailPresentation.writeLabel
        let _ = history.revision
        MetricChart(title: L10n.string("Disk Activity"),
                    series: ids.compactMap { history.series($0, range: range) },
                    labels: [DiskDetailModel.readSeries: read, DiskDetailModel.writeSeries: write],
                    style: .line,
                    range: range)
        SeriesStatsRow(statistics: history.statistics(DiskDetailModel.readSeries, range: range),
                       unit: .bytesPerSecond, title: read)
        SeriesStatsRow(statistics: history.statistics(DiskDetailModel.writeSeries, range: range),
                       unit: .bytesPerSecond, title: write)
    }
}

/// Used, purgeable and available space as one bar.
private struct DiskCapacityBar: View {
    let segments: DiskDetailPresentation.CapacitySegments

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                Rectangle().fill(DiskCapacityPart.used.color)
                    .frame(width: width * clamp(segments.used))
                Rectangle().fill(DiskCapacityPart.purgeable.color)
                    .frame(width: width * clamp(segments.purgeable))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(DiskCapacityPart.available.color)
        .clipShape(Capsule())
        // The rows below say the same in words.
        .accessibilityHidden(true)
    }

    private func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(max(value.isFinite ? value : 0, 0), 1))
    }
}

/// The bar's colors (the card's purple), also shown next to the matching capacity rows.
extension DiskCapacityPart {
    var color: Color {
        switch self {
        case .used: return .purple
        case .purgeable: return .purple.opacity(0.4)
        case .available: return Color.secondary.opacity(0.2)
        }
    }
}

/// Label / value lines; each is one VoiceOver element.
private struct DiskDetailRows: View {
    let rows: [DiskDetailRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    if let part = row.part {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                    }
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibility)
            }
        }
    }
}

private struct DiskVolumeRow: View {
    let volume: DiskVolumeInfo
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: DiskDetailPresentation.kindIcon(volume.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(volume.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DiskDetailPresentation.kindLabel(volume.kind))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(DiskDetailPresentation.freeOfTotal(free: volume.freeBytes, total: volume.totalBytes,
                                                        locale: locale))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.caption)
            DiskCapacityBar(segments: DiskDetailPresentation.segments(volume))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiskDetailPresentation.volumeAccessibility(volume, locale: locale))
    }
}

private struct DiskProcessRow: View {
    let process: ProcessUsage
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon = process.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DiskDetailPresentation.processDetail(process, locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(ByteRate.short(process.diskBytesPerSecond, locale: locale))
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiskDetailPresentation.processAccessibility(process, locale: locale))
    }
}
