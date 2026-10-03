import Accessibility
import Foundation
import SwiftUI

/// The audio graph VoiceOver offers for a `MetricChart`: the time axis, the
/// value axis spoken in the chart's unit, and one data series per metric with
/// gaps left out (they are absent samples, not zeros).
struct MetricChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let model: MetricChartModel
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent

    /// "Last 5 minutes. Now: User 23.4 percent, System 5.0 percent".
    var summary: String {
        let range = model.range.chartSpokenLabel
        let latest = model.series.compactMap { series in
            series.latest.map { "\(series.label) \(MetricValueFormat.spoken($0.value, unit: model.unit, locale: locale))" }
        }
        guard !latest.isEmpty else { return L10n.string("Last \(range)") }
        let now = latest.joined(separator: ", ")
        return L10n.string("Last \(range). Now: \(now)")
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = model.unit
        let locale = locale
        let timeZone = timeZone
        let seconds = model.timeScale.showsSeconds
        let time = model.timeScale.domain
        let xAxis = AXNumericDataAxisDescriptor(
            title: L10n.string("Time"),
            range: time.lowerBound.timeIntervalSince1970...time.upperBound.timeIntervalSince1970,
            gridlinePositions: model.timeScale.ticks.map(\.timeIntervalSince1970),
            valueDescriptionProvider: { value in
                MetricValueFormat.time(Date(timeIntervalSince1970: value), seconds: seconds,
                                       locale: locale, timeZone: timeZone)
            })
        let yAxis = AXNumericDataAxisDescriptor(
            title: L10n.string("Value"),
            range: model.valueScale.domain,
            gridlinePositions: model.valueScale.ticks,
            valueDescriptionProvider: { MetricValueFormat.spoken($0, unit: unit, locale: locale) })
        let series = model.series.map { series in
            AXDataSeriesDescriptor(
                name: series.label,
                isContinuous: true,
                dataPoints: Self.dataPoints(of: series).map { AXDataPoint(x: $0.x, y: $0.y) })
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: series)
    }

    /// The (time, reading) pairs the audio graph plays for a series: its own
    /// readings even when stacked, with gaps left out.
    static func dataPoints(of series: MetricChartModel.Series) -> [(x: Double, y: Double)] {
        series.points.compactMap { point in
            point.value.map { (point.date.timeIntervalSince1970, $0) }
        }
    }
}
