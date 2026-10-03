import Foundation

/// The Fan page's text, kept out of the views so it can be tested.
enum FanDetailPresentation {

    /// History series of the second fan, recorded only while the page is visible.
    /// The first fan is the engine's `fan.rpm`; further fans are not charted (the
    /// history store's budget allows one extra series here).
    static let secondFanSeries = "fan.rpm.1"

    /// The chart's series ids for this many fans.
    static func seriesIDs(fanCount: Int) -> [String] {
        fanCount > 1 ? [MetricSeriesID.fanRPM, secondFanSeries] : [MetricSeriesID.fanRPM]
    }

    /// "Fan" on a single-fan Mac, "Fan 1", "Fan 2"… when there are several.
    static func title(index: Int, fanCount: Int) -> String {
        guard fanCount > 1 else { return L10n.string("Fan") }
        return L10n.string("Fan \(String(index + 1))")
    }

    /// "2610 RPM" and its spoken form, as on the card and the chart.
    static func rpm(_ value: Int, locale: Locale = .autoupdatingCurrent) -> (text: String, spoken: String) {
        (MetricValueFormat.short(Double(value), unit: .rpm, locale: locale),
         MetricValueFormat.spoken(Double(value), unit: .rpm, locale: locale))
    }

    /// "40% of max" under the gauge, or nil without both a current and a maximum speed.
    static func shareOfMaximum(_ fan: FanDetail, locale: Locale = .autoupdatingCurrent) -> (text: String, spoken: String)? {
        guard let fraction = fan.fractionOfMaximum else { return nil }
        let percent = MetricFormat.percent(fraction * 100, digits: 0, locale: locale)
        let spoken = MetricFormat.decimal(fraction * 100, digits: 0, locale: locale)
        return (L10n.string("\(percent) of max"), L10n.string("\(spoken) percent of maximum speed"))
    }

    /// A fan's current speed in the headline.
    struct HeadlineItem: Equatable, Identifiable {
        let index: Int
        let rpm: Int

        var id: Int { index }
    }

    /// The card's reading for the first fan, so the page agrees with the card, then the
    /// sampler's reading for every other fan. Fans without a current speed are left out.
    static func headline(cardRPM: Int?, report: FanDetailReport?) -> [HeadlineItem] {
        var items: [HeadlineItem] = []
        if let first = cardRPM ?? report?.fans.first(where: { $0.index == 0 })?.current {
            items.append(HeadlineItem(index: 0, rpm: first))
        }
        for fan in report?.fans ?? [] where fan.index > 0 {
            if let current = fan.current { items.append(HeadlineItem(index: fan.index, rpm: current)) }
        }
        return items
    }

    /// One label / value row of a fan.
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        let spoken: String

        var id: String { label }
    }

    /// Minimum, maximum and target speed, each only when the SMC reports it.
    static func rows(_ fan: FanDetail, locale: Locale = .autoupdatingCurrent) -> [Row] {
        let items: [(String, Int?)] = [
            (L10n.string("Minimum"), fan.minimum),
            (L10n.string("Maximum"), fan.maximum),
            (L10n.string("Target"), fan.target),
        ]
        return items.compactMap { label, value in
            guard let value else { return nil }
            let formatted = rpm(value, locale: locale)
            return Row(label: label, value: formatted.text, spoken: formatted.spoken)
        }
    }
}
