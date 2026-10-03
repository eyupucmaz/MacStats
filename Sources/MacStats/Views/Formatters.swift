import Foundation

/// Shared pieces of the per-kind formatters below. Every number goes through
/// `decimal(_:digits:locale:)` so the decimal separator follows the user's locale.
enum MetricFormat {
    /// Shown wherever a reading is unavailable; never a fabricated "0".
    static let unavailable = "—"

    static func decimal(_ value: Double, digits: Int, locale: Locale) -> String {
        let value = value.isFinite ? max(value, 0) : 0
        return value.formatted(.number
            .precision(.fractionLength(digits))
            .rounded(rule: .toNearestOrAwayFromZero)
            .grouping(.never)
            .locale(locale))
    }

    /// e.g. "23.4%" / "23%"; Turkish puts the sign first ("%23,4").
    static func percent(_ value: Double, digits: Int, locale: Locale) -> String {
        percent(decimal(value, digits: digits, locale: locale))
    }

    /// Attaches the percent sign to an already formatted number.
    static func percent(_ number: String) -> String {
        L10n.string("\(number)%")
    }

    /// Scales a byte count into decimal (SI) units, the convention Finder uses.
    /// One decimal below 10, none above, and the unit steps up once rounding reaches 1000,
    /// so 999.96 KB reads "1.0 MB" rather than "1000 KB".
    static func decimalBytes(_ bytes: Double, locale: Locale) -> (number: String, unit: ByteUnit) {
        let bytes = bytes.isFinite ? max(bytes, 0) : 0
        for unit in ByteUnit.allCases {
            let value = bytes / unit.scale
            let digits = unit == .byte || value >= 9.95 ? 0 : 1
            let step = digits == 0 ? 1.0 : 10.0
            let rounded = (value * step).rounded() / step
            if rounded < 1000 || unit == ByteUnit.allCases.last {
                return (decimal(value, digits: digits, locale: locale), unit)
            }
        }
        return ("0", .byte)
    }

    enum ByteUnit: CaseIterable {
        case byte, kilo, mega, giga, tera

        var scale: Double {
            switch self {
            case .byte: return 1
            case .kilo: return 1e3
            case .mega: return 1e6
            case .giga: return 1e9
            case .tera: return 1e12
            }
        }

        var symbol: String {
            switch self {
            case .byte: return "B"
            case .kilo: return "KB"
            case .mega: return "MB"
            case .giga: return "GB"
            case .tera: return "TB"
            }
        }

        /// Unit symbols are international and stay as they are; the spoken
        /// names are what VoiceOver reads, so they are localized.
        var spoken: String {
            switch self {
            case .byte: return L10n.string("bytes")
            case .kilo: return L10n.string("kilobytes")
            case .mega: return L10n.string("megabytes")
            case .giga: return L10n.string("gigabytes")
            case .tera: return L10n.string("terabytes")
            }
        }
    }
}

/// RAM in binary units labelled "GB", as Activity Monitor and About This Mac do
/// (16 GiB of RAM is sold and shown as "16 GB").
enum MemorySize {
    private static let gibibyte = 1_073_741_824.0

    /// Card form, e.g. "8.2/16 GB".
    static func usedOfTotal(_ used: UInt64, _ total: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        "\(gigabytes(used, locale))/\(gigabytes(total, locale, digits: 0)) GB"
    }

    /// Menu bar form, e.g. "8.2G".
    static func compact(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        gigabytes(bytes, locale) + "G"
    }

    /// Spelled-out form for VoiceOver.
    static func spoken(used: UInt64, total: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        L10n.string("\(gigabytes(used, locale)) of \(gigabytes(total, locale, digits: 0)) gigabytes used")
    }

    /// One decimal below 100 GB; above that the tenth is noise.
    private static func gigabytes(_ bytes: UInt64, _ locale: Locale, digits: Int? = nil) -> String {
        let value = Double(bytes) / gibibyte
        return MetricFormat.decimal(value, digits: digits ?? (value < 99.95 ? 1 : 0), locale: locale)
    }
}

/// Storage sizes in decimal units, matching Finder and About This Mac.
enum DiskSize {
    /// e.g. "820 MB", "9.7 GB", "245 GB", "1.2 TB".
    static func short(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = MetricFormat.decimalBytes(Double(bytes), locale: locale)
        return "\(scaled.number) \(scaled.unit.symbol)"
    }

    /// Spelled-out form for VoiceOver.
    static func spoken(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = MetricFormat.decimalBytes(Double(bytes), locale: locale)
        return "\(scaled.number) \(scaled.unit.spoken)"
    }
}

/// Network throughput in decimal units, the networking convention and the same
/// units `DiskSize` uses. Sub-megabyte rates must not collapse to "0".
enum ByteRate {
    /// Card form, e.g. "0 B/s", "812 KB/s", "1.2 MB/s".
    static func short(_ bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = MetricFormat.decimalBytes(bytesPerSecond, locale: locale)
        return L10n.string("\(scaled.number) \(scaled.unit.symbol)/s")
    }

    /// Menu bar form, e.g. "812K", "1.2M": no space, no "B/s" — the menu bar pays
    /// for every point of width.
    static func compact(_ bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = MetricFormat.decimalBytes(bytesPerSecond, locale: locale)
        return scaled.number + String(scaled.unit.symbol.prefix(1))
    }

    /// Spelled-out form for VoiceOver.
    static func spoken(_ bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = MetricFormat.decimalBytes(bytesPerSecond, locale: locale)
        return L10n.string("\(scaled.number) \(scaled.unit.spoken) per second")
    }
}

/// Any `MetricUnit` reading, for the detail charts (#23): tooltip, legend and
/// stats values, axis ticks, and the spoken form VoiceOver reads. Built on the
/// formatters above so a chart reads the same as the card it came from.
enum MetricValueFormat {
    /// Tooltip / legend / stats form, e.g. "23.4%", "1.2 MB/s", "2502 RPM", "53.4°C".
    static func short(_ value: Double, unit: MetricUnit, locale: Locale = .autoupdatingCurrent) -> String {
        switch unit {
        case .percent:
            return MetricFormat.percent(value, digits: 1, locale: locale)
        case .bytes:
            let scaled = MetricFormat.decimalBytes(value, locale: locale)
            return "\(scaled.number) \(scaled.unit.symbol)"
        case .bytesPerSecond:
            return ByteRate.short(value, locale: locale)
        case .rpm:
            return L10n.string("\(MetricFormat.decimal(value, digits: 0, locale: locale)) RPM")
        case .celsius:
            return MetricFormat.decimal(value, digits: 1, locale: locale) + "°C"
        case .watts:
            return MetricFormat.decimal(value, digits: value < 9.95 ? 1 : 0, locale: locale) + " W"
        case .count:
            return MetricFormat.decimal(value, digits: value == value.rounded() ? 0 : 1, locale: locale)
        }
    }

    /// Axis tick label: as `short`, but with only as many decimals as the tick
    /// `step` needs ("50%", "55°C", "0.5 W"), so labels stay narrow and distinct.
    static func axis(_ value: Double, unit: MetricUnit, step: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let digits = step >= 1 ? 0 : step >= 0.1 ? 1 : 2
        switch unit {
        case .percent:
            return MetricFormat.percent(value, digits: 0, locale: locale)
        case .bytes, .bytesPerSecond, .rpm:
            return short(value, unit: unit, locale: locale)
        case .celsius:
            return MetricFormat.decimal(value, digits: digits, locale: locale) + "°C"
        case .watts:
            return MetricFormat.decimal(value, digits: digits, locale: locale) + " W"
        case .count:
            return MetricFormat.decimal(value, digits: digits, locale: locale)
        }
    }

    /// Spelled-out form for VoiceOver and the chart's audio graph.
    static func spoken(_ value: Double, unit: MetricUnit, locale: Locale = .autoupdatingCurrent) -> String {
        switch unit {
        case .percent:
            return L10n.string("\(MetricFormat.decimal(value, digits: 1, locale: locale)) percent")
        case .bytes:
            let scaled = MetricFormat.decimalBytes(value, locale: locale)
            return "\(scaled.number) \(scaled.unit.spoken)"
        case .bytesPerSecond:
            return ByteRate.spoken(value, locale: locale)
        case .rpm:
            return L10n.string("\(MetricFormat.decimal(value, digits: 0, locale: locale)) revolutions per minute")
        case .celsius:
            return L10n.string("\(MetricFormat.decimal(value, digits: 1, locale: locale)) degrees Celsius")
        case .watts:
            return L10n.string("\(MetricFormat.decimal(value, digits: value < 9.95 ? 1 : 0, locale: locale)) watts")
        case .count:
            return short(value, unit: .count, locale: locale)
        }
    }

    /// Clock time of a sample in the user's 12/24-hour style, e.g. "14:03:27";
    /// `seconds: false` gives "14:03".
    static func time(_ date: Date, seconds: Bool = true, locale: Locale = .autoupdatingCurrent,
                     timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        if seconds { style = style.second() }
        return date.formatted(style)
    }
}
