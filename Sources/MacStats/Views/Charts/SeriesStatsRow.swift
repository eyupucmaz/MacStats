import SwiftUI

/// "Min 12% · Avg 34% · Max 80%" under a chart, for the visible range.
/// Pages with several series place one row per series and pass its `title`.
struct SeriesStatsRow: View {
    let statistics: SeriesStatistics?
    let unit: MetricUnit
    var title: String? = nil

    @Environment(\.locale) private var locale

    var body: some View {
        let summary = SeriesStatsSummary(statistics: statistics, unit: unit, title: title, locale: locale)
        HStack(spacing: 12) {
            if let title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            ForEach(summary.items, id: \.label) { item in
                HStack(spacing: 4) {
                    Text(item.label).foregroundStyle(.secondary)
                    Text(item.value).monospacedDigit()
                }
                .lineLimit(1)
            }
            if title == nil { Spacer(minLength: 0) }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
    }
}

/// The text of a `SeriesStatsRow`, kept out of the view so it can be tested.
struct SeriesStatsSummary: Equatable {
    struct Item: Equatable {
        let label: String
        let value: String
    }

    let items: [Item]
    let accessibilityLabel: String

    init(statistics: SeriesStatistics?, unit: MetricUnit, title: String? = nil,
         locale: Locale = .autoupdatingCurrent) {
        func short(_ value: Double?) -> String {
            value.map { MetricValueFormat.short($0, unit: unit, locale: locale) } ?? MetricFormat.unavailable
        }
        items = [
            Item(label: L10n.string("Min"), value: short(statistics?.min)),
            Item(label: L10n.string("Avg"), value: short(statistics?.average)),
            Item(label: L10n.string("Max"), value: short(statistics?.max)),
        ]

        let spoken: String
        if let statistics {
            let min = MetricValueFormat.spoken(statistics.min, unit: unit, locale: locale)
            let average = MetricValueFormat.spoken(statistics.average, unit: unit, locale: locale)
            let max = MetricValueFormat.spoken(statistics.max, unit: unit, locale: locale)
            spoken = L10n.string("Minimum \(min), average \(average), maximum \(max)")
        } else {
            spoken = L10n.string("No statistics yet")
        }
        accessibilityLabel = title.map { "\($0), \(spoken)" } ?? spoken
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        SeriesStatsRow(statistics: SeriesStatistics(min: 4.2, average: 23.4, max: 81), unit: .percent)
        SeriesStatsRow(statistics: SeriesStatistics(min: 0, average: 412_000, max: 2_300_000),
                       unit: .bytesPerSecond, title: "Download")
        SeriesStatsRow(statistics: nil, unit: .celsius)
    }
    .padding()
    .frame(width: 340)
}
