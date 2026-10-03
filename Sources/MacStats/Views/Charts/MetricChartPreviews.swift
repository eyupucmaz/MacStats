#if DEBUG
import SwiftUI

/// Deterministic sample data for the chart previews: smooth waves at 1 s
/// spacing ending at a fixed date, optionally with a sampling gap.
enum MetricChartFixtures {
    static let end = Date(timeIntervalSince1970: 1_790_000_000)

    static func series(_ id: String, unit: MetricUnit, range: HistoryRange = .default,
                       base: Double, amplitude: Double, phase: Double = 0,
                       gap: Range<Int>? = nil) -> MetricSeries {
        let count = min(Int(range.duration), 300)
        let step = range.duration / Double(count)
        let points = (0..<count).map { index -> MetricPoint in
            let date = end.addingTimeInterval(-Double(count - 1 - index) * step)
            if let gap, gap.contains(index) { return MetricPoint(date: date, value: nil) }
            let t = Double(index) / 18 + phase
            let wave = sin(t) * 0.6 + sin(t * 2.7 + 1) * 0.3 + sin(t * 7.1) * 0.1
            return MetricPoint(date: date, value: max(base + amplitude * wave, 0))
        }
        return MetricSeries(id: id, unit: unit, points: points)
    }
}

private struct ChartPreviewPage<Chart: View>: View {
    let title: String
    let statistics: SeriesStatistics?
    let unit: MetricUnit
    @ViewBuilder let chart: (HistoryRange) -> Chart
    @State private var range = HistoryRange.default

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                HistoryRangePicker(selection: $range)
            }
            chart(range)
            SeriesStatsRow(statistics: statistics, unit: unit)
        }
        .padding(12)
        .frame(width: 340)
    }
}

#Preview("Line · CPU") {
    ChartPreviewPage(title: "CPU", statistics: SeriesStatistics(min: 8, average: 31.5, max: 62), unit: .percent) { range in
        MetricChart(title: "CPU",
                    series: [MetricChartFixtures.series("cpu.total", unit: .percent, base: 35, amplitude: 30)],
                    labels: ["cpu.total": "Total"],
                    range: range, end: MetricChartFixtures.end)
    }
}

#Preview("Area · Network") {
    ChartPreviewPage(title: "Network", statistics: SeriesStatistics(min: 0, average: 640_000, max: 2_100_000),
                     unit: .bytesPerSecond) { range in
        MetricChart(title: "Network",
                    series: [MetricChartFixtures.series("net.down", unit: .bytesPerSecond, base: 900_000, amplitude: 1_200_000),
                             MetricChartFixtures.series("net.up", unit: .bytesPerSecond, base: 200_000, amplitude: 250_000, phase: 2)],
                    labels: ["net.down": "Download", "net.up": "Upload"],
                    style: .area, range: range, end: MetricChartFixtures.end)
    }
}

#Preview("Stacked · CPU user/system") {
    ChartPreviewPage(title: "CPU", statistics: SeriesStatistics(min: 12, average: 38, max: 71), unit: .percent) { range in
        MetricChart(title: "CPU",
                    series: [MetricChartFixtures.series("cpu.user", unit: .percent, base: 25, amplitude: 20),
                             MetricChartFixtures.series("cpu.system", unit: .percent, base: 10, amplitude: 8, phase: 1.5)],
                    labels: ["cpu.user": "User", "cpu.system": "System"],
                    style: .stackedArea, range: range, end: MetricChartFixtures.end)
    }
}

#Preview("Gaps · four series") {
    ChartPreviewPage(title: "Temperature", statistics: SeriesStatistics(min: 41.2, average: 55.7, max: 78.4),
                     unit: .celsius) { range in
        MetricChart(title: "Temperature",
                    series: (0..<4).map { index in
                        MetricChartFixtures.series("temp.\(index)", unit: .celsius, base: 50 + Double(index) * 6,
                                                   amplitude: 10, phase: Double(index), gap: 120..<170)
                    },
                    labels: ["temp.0": "CPU", "temp.1": "GPU", "temp.2": "SoC", "temp.3": "Battery"],
                    range: range, end: MetricChartFixtures.end)
    }
}

#Preview("Empty · Turkish locale") {
    ChartPreviewPage(title: "Fan", statistics: nil, unit: .rpm) { range in
        MetricChart(title: "Fan",
                    series: [MetricSeries(id: "fan.0", unit: .rpm,
                                          points: [MetricPoint(date: MetricChartFixtures.end, value: 2_400)])],
                    range: range)
    }
    .environment(\.locale, Locale(identifier: "tr_TR"))
}
#endif
