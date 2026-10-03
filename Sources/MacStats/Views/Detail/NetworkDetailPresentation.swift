import Foundation

/// The Network page's text, kept out of the views so it can be tested.
enum NetworkDetailFormat {

    // MARK: Bit rates (link speed, Wi-Fi transmit rate)

    /// Bits per second in decimal units, the networking convention: "1 Gb/s",
    /// "2.5 Gb/s", "866 Mb/s", "5.5 Mb/s". A tenth is shown only when there is one.
    static func bitRate(_ bitsPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = scaleBits(bitsPerSecond, locale: locale)
        return L10n.string("\(scaled.number) \(scaled.symbol)/s")
    }

    static func spokenBitRate(_ bitsPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let scaled = scaleBits(bitsPerSecond, locale: locale)
        return L10n.string("\(scaled.number) \(scaled.spoken) per second")
    }

    private static func scaleBits(_ bits: Double, locale: Locale) -> (number: String, symbol: String, spoken: String) {
        let bits = bits.isFinite ? max(bits, 0) : 0
        let units: [(scale: Double, symbol: String, spoken: String)] = [
            (1e9, "Gb", L10n.string("gigabits")),
            (1e6, "Mb", L10n.string("megabits")),
            (1e3, "kb", L10n.string("kilobits")),
        ]
        let unit = units.first { (bits / $0.scale * 10).rounded() / 10 >= 1 } ?? units[units.count - 1]
        let value = bits / unit.scale
        let tenths = (value * 10).rounded() / 10
        let digits = value < 100 && tenths != tenths.rounded() ? 1 : 0
        return (MetricFormat.decimal(value, digits: digits, locale: locale), unit.symbol, unit.spoken)
    }

    // MARK: Wi-Fi

    /// Signal and noise levels, e.g. "-62 dBm". Plain integers, so `String(_:)`.
    static func dBm(_ value: Int) -> String {
        L10n.string("\(String(value)) dBm")
    }

    static func spokenDBm(_ value: Int) -> String {
        L10n.string("\(String(value)) decibel-milliwatts")
    }

    static func band(_ band: WiFiDetails.Band) -> String {
        switch band {
        case .ghz2_4: return L10n.string("2.4 GHz")
        case .ghz5: return L10n.string("5 GHz")
        case .ghz6: return L10n.string("6 GHz")
        }
    }

    /// "36 (5 GHz)", or just "36" when the band is unknown.
    static func channel(_ number: Int, band: WiFiDetails.Band?) -> String {
        guard let band else { return String(number) }
        return L10n.string("\(String(number)) (\(Self.band(band)))")
    }

    // MARK: Interfaces

    static func kind(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .wifi: return L10n.string("Wi-Fi")
        case .ethernet: return L10n.string("Ethernet")
        case .other: return L10n.string("Other")
        }
    }

    static func kindIcon(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        }
    }

    /// "Wi-Fi, en0" / "Wi-Fi, en0, primary" for VoiceOver.
    static func spokenInterface(_ detail: NetworkInterfaceDetail) -> String {
        let named = L10n.string("\(kind(detail.kind)), \(detail.name)")
        guard detail.isPrimary else { return named }
        let primary = L10n.string("primary")
        return L10n.string("\(named), \(primary)")
    }

    // MARK: Down / up pairs

    /// One row of down/up values, e.g. totals or rates.
    struct Pair: Equatable {
        let down: String
        let up: String
        let spoken: String
    }

    /// Byte totals, "↓2.1 GB" / "↑310 MB", or nil when not measured.
    static func totals(_ totals: NetworkTrafficLedger.Totals?, title: String,
                       locale: Locale = .autoupdatingCurrent) -> Pair? {
        guard let totals else { return nil }
        let down = DiskSize.spoken(totals.inputBytes, locale: locale)
        let up = DiskSize.spoken(totals.outputBytes, locale: locale)
        return Pair(down: "↓" + DiskSize.short(totals.inputBytes, locale: locale),
                    up: "↑" + DiskSize.short(totals.outputBytes, locale: locale),
                    spoken: L10n.string("\(title), download \(down), upload \(up)"))
    }

    /// Rates, "↓1.2 MB/s" / "↑80 KB/s"; dashes before the first interval.
    static func rates(down: Double?, up: Double?, title: String,
                      locale: Locale = .autoupdatingCurrent) -> Pair {
        guard let down, let up else {
            let collecting = L10n.string("Collecting data…")
            return Pair(down: "↓" + MetricFormat.unavailable, up: "↑" + MetricFormat.unavailable,
                        spoken: L10n.string("\(title), \(collecting)"))
        }
        let spokenDown = ByteRate.spoken(down, locale: locale)
        let spokenUp = ByteRate.spoken(up, locale: locale)
        return Pair(down: "↓" + ByteRate.short(down, locale: locale),
                    up: "↑" + ByteRate.short(up, locale: locale),
                    spoken: L10n.string("\(title), download \(spokenDown), upload \(spokenUp)"))
    }
}
