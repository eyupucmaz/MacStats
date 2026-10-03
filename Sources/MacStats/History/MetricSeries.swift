import Foundation

// Shared contract between the history store (#22), the chart component (#23)
// and the detail pages (#25–#32). Keep it small: the store produces these
// values, charts only read them.

/// One sample in a series. A nil value marks a gap (no sampling happened), so
/// charts break the line there instead of interpolating across it.
struct MetricPoint: Equatable {
    let date: Date
    let value: Double?
}

/// What a series measures; charts pick axis formatting from it.
enum MetricUnit: Equatable {
    case percent
    case bytes
    case bytesPerSecond
    case rpm
    case celsius
    case watts
    case count
}

/// A time-ordered series ready to draw, already cut to a `HistoryRange` and
/// downsampled for display.
struct MetricSeries: Identifiable, Equatable {
    /// Stable identifier such as "cpu.user"; also used as the chart legend key.
    let id: String
    let unit: MetricUnit
    var points: [MetricPoint]
}

/// Min / average / max over the non-gap points of a range.
struct SeriesStatistics: Equatable {
    let min: Double
    let average: Double
    let max: Double
}

/// The time windows a detail page can show.
enum HistoryRange: String, CaseIterable, Identifiable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    static let `default`: HistoryRange = .fiveMinutes

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .oneHour: return 3_600
        }
    }
}
