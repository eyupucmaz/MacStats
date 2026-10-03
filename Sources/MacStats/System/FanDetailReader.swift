import Foundation

/// One fan as the SMC reports it. Every speed is optional: a key the SMC does not
/// have is hidden on the page, never shown as 0.
struct FanDetail: Equatable, Identifiable {
    /// Zero-based SMC index (`F0…`); the page numbers fans from 1.
    let index: Int
    var current: Int?
    var minimum: Int?
    var maximum: Int?
    var target: Int?

    var id: Int { index }

    /// Current speed as a share of the maximum, 0...1; nil without both values.
    var fractionOfMaximum: Double? {
        guard let current, let maximum, maximum > 0 else { return nil }
        return min(max(Double(current) / Double(maximum), 0), 1)
    }
}

/// Everything the Fan page (#31) shows beyond the card's first-fan RPM.
struct FanDetailReport: Equatable {
    /// The fan count (`FNum`); nil when the SMC could not be asked.
    var count: Int?
    var fans: [FanDetail]

    /// The SMC answered and says there is no fan: the Mac is cooled passively.
    var isFanless: Bool { count == 0 && fans.isEmpty }
}

/// Where `FanDetailReader` gets its readings, injectable for tests.
protocol FanDetailSource: AnyObject {
    /// False when the SMC could not be opened at all.
    var isAvailable: Bool { get }
    func fanCount() -> Int?
    func rpm(fan index: Int, _ value: SMCService.FanValue) -> Int?
}

final class LiveFanDetailSource: FanDetailSource {
    var isAvailable: Bool { SMCService.shared.isAvailable }
    func fanCount() -> Int? { SMCService.shared.readFanCount() }
    func rpm(fan index: Int, _ value: SMCService.FanValue) -> Int? {
        SMCService.shared.readFanRPM(index: index, value)
    }
}

/// Turns raw SMC fan keys into a `FanDetailReport`. Read-only: four key reads per fan.
enum FanDetailReader {
    /// More than any Mac has (a Mac Pro has four); bounds a garbage `FNum`.
    static let maximumFans = 8

    static func read(from source: FanDetailSource) -> FanDetailReport {
        let reported = source.fanCount().map { min($0, maximumFans) }
        // Without `FNum`, count the fans whose speed reads, in order.
        let count = reported ?? (0..<maximumFans).prefix { source.rpm(fan: $0, .actual) != nil }.count
        let fans = (0..<count).compactMap { index -> FanDetail? in
            let fan = FanDetail(index: index,
                                current: source.rpm(fan: index, .actual),
                                minimum: source.rpm(fan: index, .minimum),
                                // A maximum of 0 cannot be right, and would make every gauge full.
                                maximum: source.rpm(fan: index, .maximum).flatMap { $0 > 0 ? $0 : nil },
                                target: source.rpm(fan: index, .target))
            // A fan none of whose keys read has nothing to show.
            let values = [fan.current, fan.minimum, fan.maximum, fan.target]
            return values.allSatisfy { $0 == nil } ? nil : fan
        }
        if reported == nil, fans.isEmpty {
            // An open SMC without fan keys belongs to a fanless Mac; a closed one tells us nothing.
            return FanDetailReport(count: source.isAvailable ? 0 : nil, fans: [])
        }
        return FanDetailReport(count: reported ?? count, fans: fans)
    }
}
