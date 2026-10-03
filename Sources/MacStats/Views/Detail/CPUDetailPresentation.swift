import Foundation
import SwiftUI

/// The text and numbers of the CPU page, kept out of the views so the wording,
/// grouping and "hide what is missing" rules are unit-tested. Text comes from
/// `L10n`; `locale` only decides how numbers are written.
enum CPUDetailPresentation {

    // MARK: - Headline

    /// The latest engine reading split into user / system / idle, all 0...100.
    struct Headline: Equatable {
        let total: Double
        let user: Double
        let system: Double
        let idle: Double
    }

    /// Nil until the engine has recorded a reading with all three values (they are
    /// recorded together, from one sample). Idle is what the busy share leaves.
    static func headline(total: Double?, user: Double?, system: Double?) -> Headline? {
        guard let total, let user, let system, total.isFinite, user.isFinite, system.isFinite else { return nil }
        func clamp(_ value: Double) -> Double { min(max(value, 0), 100) }
        return Headline(total: clamp(total), user: clamp(user), system: clamp(system), idle: clamp(100 - total))
    }

    static func percent(_ value: Double, digits: Int = 1, locale: Locale) -> String {
        MetricFormat.percent(value, digits: digits, locale: locale)
    }

    static func spokenPercent(_ value: Double, locale: Locale) -> String {
        MetricValueFormat.spoken(value, unit: .percent, locale: locale)
    }

    // MARK: - Cores

    /// The groups the bars are drawn in. `info.groups` when they cover exactly the
    /// cores `host_processor_info` reported, otherwise one group of them all.
    static func coreGroups(_ groups: [CPUCoreGroup], coreCount: Int) -> [CPUCoreGroup] {
        guard coreCount > 0 else { return [] }
        let covered = groups.reduce(0) { $0 + $1.cores.count }
        let fits = covered == coreCount && groups.allSatisfy { $0.cores.upperBound <= coreCount }
        return fits ? groups : [CPUCoreGroup(kind: .all, cores: 0..<coreCount)]
    }

    /// "Performance cores", "Efficiency cores", … — macOS's own perf-level name,
    /// translated where it is a known one.
    static func title(of group: CPUCoreGroup) -> String {
        guard case .perfLevel(let level, let name) = group.kind else { return L10n.string("Cores") }
        switch name?.lowercased() {
        case "performance": return L10n.string("Performance cores")
        case "efficiency": return L10n.string("Efficiency cores")
        case "super": return L10n.string("Super cores")
        case .some:
            let name = name ?? ""
            return L10n.string("\(name) cores")
        case nil:
            return level == 0 ? L10n.string("Performance cores") : L10n.string("Efficiency cores")
        }
    }

    /// Mean load of the group's measured cores; nil when none was measured.
    static func average(of group: CPUCoreGroup, in cores: [CPUSample?]) -> Double? {
        let values = group.cores.compactMap { cores.indices.contains($0) ? cores[$0]?.total : nil }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// "23 percent": bars and group averages are shown as whole percents.
    static func spokenWholePercent(_ value: Double, locale: Locale) -> String {
        L10n.string("\(MetricFormat.decimal(value, digits: 0, locale: locale)) percent")
    }

    /// "Core 7, 23 percent" — numbered from 1 across the whole chip, like Activity Monitor.
    static func spokenCore(_ index: Int, load: CPUSample?, locale: Locale) -> String {
        let number = String(index + 1)
        let value = load.map { spokenWholePercent($0.total, locale: locale) } ?? L10n.string("Unavailable")
        return L10n.string("Core \(number), \(value)")
    }

    static func spokenGroup(_ group: CPUCoreGroup, cores: [CPUSample?], locale: Locale) -> (label: String, value: String) {
        let title = title(of: group)
        let label = average(of: group, in: cores).map {
            L10n.string("\(title), average \(spokenWholePercent($0, locale: locale))")
        } ?? title
        let value = group.cores
            .map { spokenCore($0, load: cores.indices.contains($0) ? cores[$0] : nil, locale: locale) }
            .joined(separator: "; ")
        return (label, value)
    }

    // MARK: - Load average

    static func load(_ value: Double, locale: Locale) -> String {
        MetricFormat.decimal(value, digits: 2, locale: locale)
    }

    struct LoadColumn: Equatable, Identifiable {
        let label: String
        /// e.g. "Load average over 5 minutes"
        let spokenLabel: String
        let value: String

        var id: String { label }
    }

    /// The 1, 5 and 15 minute averages.
    static func loadColumns(_ load: CPULoadAverage, locale: Locale) -> [LoadColumn] {
        func column(_ label: String, _ spokenRange: String, _ value: Double) -> LoadColumn {
            LoadColumn(label: label, spokenLabel: L10n.string("Load average over \(spokenRange)"),
                       value: self.load(value, locale: locale))
        }
        return [column(L10n.string("1 min"), L10n.string("1 minute"), load.one),
                column(L10n.string("5 min"), L10n.string("5 minutes"), load.five),
                column(L10n.string("15 min"), L10n.string("15 minutes"), load.fifteen)]
    }

    static func loadContext(cores: Int) -> String {
        L10n.string("Out of \(String(cores)) cores; higher means work is waiting.")
    }

    // MARK: - About

    /// "3 d 4 h", "4 h 12 min", "12 min" plus the spoken form; nil for a nonsensical interval.
    static func uptime(_ interval: TimeInterval) -> (text: String, spoken: String)? {
        guard interval.isFinite, interval >= 0 else { return nil }
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1_440, hours = totalMinutes % 1_440 / 60, minutes = totalMinutes % 60

        func spokenDays(_ n: Int) -> String { n == 1 ? L10n.string("\(String(n)) day") : L10n.string("\(String(n)) days") }
        func spokenHours(_ n: Int) -> String { n == 1 ? L10n.string("\(String(n)) hour") : L10n.string("\(String(n)) hours") }
        func spokenMinutes(_ n: Int) -> String {
            n == 1 ? L10n.string("\(String(n)) minute") : L10n.string("\(String(n)) minutes")
        }

        if days > 0 {
            return (L10n.string("\(String(days)) d \(String(hours)) h"),
                    "\(spokenDays(days)), \(spokenHours(hours))")
        }
        if hours > 0 {
            return (L10n.string("\(String(hours)) h \(String(minutes)) min"),
                    "\(spokenHours(hours)), \(spokenMinutes(minutes))")
        }
        return (L10n.string("\(String(minutes)) min"), spokenMinutes(minutes))
    }

    enum ThermalLevel: Equatable {
        case nominal, fair, serious, critical

        init?(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: return nil
            }
        }

        var text: String {
            switch self {
            case .nominal: return L10n.string("Nominal")
            case .fair: return L10n.string("Fair")
            case .serious: return L10n.string("Serious")
            case .critical: return L10n.string("Critical")
            }
        }

        var color: Color {
            switch self {
            case .nominal: return .green
            case .fair: return .yellow
            case .serious: return .orange
            case .critical: return .red
            }
        }
    }

    // MARK: - Processes

    /// Activity Monitor's convention: 100 % is one core, so a busy app can exceed 100 %.
    static func processValue(_ usage: ProcessUsage, locale: Locale) -> (text: String, spoken: String) {
        (percent(usage.cpuPercent, locale: locale),
         L10n.string("\(usage.name), \(spokenPercent(usage.cpuPercent, locale: locale))"))
    }
}
