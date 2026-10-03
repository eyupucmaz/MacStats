import Foundation

/// The parts of a volume's capacity bar.
enum DiskCapacityPart: Equatable {
    case used, purgeable, available
}

/// One label / value line of the Disk page, with the text VoiceOver reads.
struct DiskDetailRow: Equatable, Identifiable {
    let label: String
    let value: String
    let accessibility: String
    /// The bar segment this row describes, so the page can show its color beside it.
    let part: DiskCapacityPart?

    var id: String { label }

    init(_ label: String, _ value: String, spoken: String? = nil, part: DiskCapacityPart? = nil) {
        self.label = label
        self.value = value
        self.part = part
        accessibility = "\(label), \(spoken ?? value)"
    }
}

/// Every string the Disk page shows, built outside the views so wording, units and
/// what is hidden are unit-tested. Sizes use `DiskSize` and rates `ByteRate`, the
/// same units as the card. Missing values produce no row rather than a 0.
enum DiskDetailPresentation {

    // MARK: Headline (startup volume, from the snapshot the card uses)

    struct Headline: Equatable {
        let percentUsed: String
        let freeOfTotal: String
        let usedFraction: Double
        let accessibility: String
    }

    /// Nil when the engine has no capacity reading, as the card shows "—" then.
    static func headline(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> Headline? {
        guard s.diskTotalBytes > 0 else { return nil }
        let used = min(s.diskUsedBytes, s.diskTotalBytes)
        let fraction = Double(used) / Double(s.diskTotalBytes)
        let percent = MetricFormat.decimal(fraction * 100, digits: 0, locale: locale)
        return Headline(percentUsed: L10n.string("\(percent)% used"),
                        freeOfTotal: freeOfTotal(free: s.diskTotalBytes - used, total: s.diskTotalBytes,
                                                 locale: locale),
                        usedFraction: fraction,
                        accessibility: StatCardFactory.disk(s, locale: locale).accessibility)
    }

    /// e.g. "194 GB free of 494 GB".
    static func freeOfTotal(free: UInt64, total: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        L10n.string("\(DiskSize.short(free, locale: locale)) free of \(DiskSize.short(total, locale: locale))")
    }

    // MARK: Capacity breakdown

    /// The used / purgeable / available split of a volume, for the stacked bar.
    struct CapacitySegments: Equatable {
        let used: Double
        let purgeable: Double
        let available: Double
    }

    static func segments(_ volume: DiskVolumeInfo) -> CapacitySegments {
        let total = Double(volume.totalBytes)
        let purgeable = Double(volume.purgeableBytes ?? 0) / total
        return CapacitySegments(used: Double(volume.usedBytes) / total,
                                purgeable: purgeable,
                                available: Double(volume.freeBytes) / total - purgeable)
    }

    static func capacityRows(_ volume: DiskVolumeInfo, locale: Locale = .autoupdatingCurrent) -> [DiskDetailRow] {
        func size(_ label: String, _ bytes: UInt64, _ part: DiskCapacityPart) -> DiskDetailRow {
            DiskDetailRow(label, DiskSize.short(bytes, locale: locale), spoken: DiskSize.spoken(bytes, locale: locale),
                          part: part)
        }
        var rows = [DiskDetailRow(L10n.string("Volume name"), volume.name),
                    size(L10n.string("Used space"), volume.usedBytes, .used)]
        if let available = volume.availableBytes, let purgeable = volume.purgeableBytes {
            // In the bar's order: used, purgeable, available.
            rows.append(size(L10n.string("Purgeable space"), purgeable, .purgeable))
            rows.append(size(L10n.string("Available space"), available, .available))
        } else {
            rows.append(size(L10n.string("Available space"), volume.freeBytes, .available))
        }
        if let format = volume.formatDescription {
            rows.append(DiskDetailRow(L10n.string("File system"), format))
        }
        if let encrypted = volume.isEncrypted {
            rows.append(DiskDetailRow(L10n.string("Encryption"),
                                      encrypted ? L10n.string("Encrypted") : L10n.string("Not encrypted")))
        }
        return rows
    }

    // MARK: Volumes

    static func kindLabel(_ kind: DiskVolumeKind) -> String {
        switch kind {
        case .internal: return L10n.string("Internal")
        case .external: return L10n.string("External")
        case .removable: return L10n.string("Removable")
        case .network: return L10n.string("Network")
        }
    }

    static func kindIcon(_ kind: DiskVolumeKind) -> String {
        switch kind {
        case .internal: return "internaldrive"
        case .external: return "externaldrive"
        case .removable: return "sdcard"
        case .network: return "server.rack"
        }
    }

    /// e.g. "Macintosh HD, Internal, startup disk, 61 percent used, 194 gigabytes free of 494 gigabytes".
    static func volumeAccessibility(_ volume: DiskVolumeInfo, locale: Locale = .autoupdatingCurrent) -> String {
        let percent = MetricFormat.decimal(volume.usedFraction * 100, digits: 0, locale: locale)
        let free = DiskSize.spoken(volume.freeBytes, locale: locale)
        let total = DiskSize.spoken(volume.totalBytes, locale: locale)
        var parts = [volume.name, kindLabel(volume.kind)]
        if volume.isStartup { parts.append(L10n.string("startup disk")) }
        parts.append(L10n.string("\(percent) percent used, \(free) free of \(total)"))
        return parts.joined(separator: ", ")
    }

    // MARK: Activity

    static var readLabel: String { L10n.string("Read") }
    static var writeLabel: String { L10n.string("Write") }

    /// Operations per second, e.g. "1250/s".
    static func operations(_ perSecond: Double, locale: Locale = .autoupdatingCurrent) -> (text: String, spoken: String) {
        let number = MetricFormat.decimal(perSecond, digits: 0, locale: locale)
        return (L10n.string("\(number)/s"), L10n.string("\(number) per second"))
    }

    /// Operation rates (once there are two readings) and totals since startup.
    static func activityRows(_ report: DiskActivityReport, locale: Locale = .autoupdatingCurrent) -> [DiskDetailRow] {
        var rows: [DiskDetailRow] = []
        if let rates = report.rates {
            let read = operations(rates.readOperationsPerSecond, locale: locale)
            let write = operations(rates.writeOperationsPerSecond, locale: locale)
            rows.append(DiskDetailRow(L10n.string("Read operations"), read.text, spoken: read.spoken))
            rows.append(DiskDetailRow(L10n.string("Write operations"), write.text, spoken: write.spoken))
        }
        func total(_ label: String, _ bytes: UInt64) -> DiskDetailRow {
            DiskDetailRow(label, DiskSize.short(bytes, locale: locale), spoken: DiskSize.spoken(bytes, locale: locale))
        }
        rows.append(total(L10n.string("Read since startup"), report.totals.readBytes))
        rows.append(total(L10n.string("Written since startup"), report.totals.writeBytes))
        return rows
    }

    // MARK: Top processes

    /// Rows with disk traffic, heaviest first. Idle processes are left out so the
    /// list does not fill up with "0 B/s".
    static func topProcesses(_ report: ProcessReport, count: Int = 5) -> [ProcessUsage] {
        Array(report.top(.diskIO, count: report.processes.count)
            .prefix { $0.diskBytesPerSecond > 0 }
            .prefix(count))
    }

    /// e.g. "Read 1.2 MB/s · Write 340 KB/s".
    static func processDetail(_ process: ProcessUsage, locale: Locale = .autoupdatingCurrent) -> String {
        let read = ByteRate.short(process.diskReadBytesPerSecond, locale: locale)
        let write = ByteRate.short(process.diskWriteBytesPerSecond, locale: locale)
        return L10n.string("Read \(read) · Write \(write)")
    }

    static func processAccessibility(_ process: ProcessUsage, locale: Locale = .autoupdatingCurrent) -> String {
        let read = ByteRate.spoken(process.diskReadBytesPerSecond, locale: locale)
        let write = ByteRate.spoken(process.diskWriteBytesPerSecond, locale: locale)
        return L10n.string("\(process.name), reading \(read), writing \(write)")
    }

    // MARK: About

    static func aboutRows(_ drive: DiskDriveInfo) -> [DiskDetailRow] {
        var rows: [DiskDetailRow] = []
        if let model = drive.model { rows.append(DiskDetailRow(L10n.string("Drive model"), model)) }
        if let solid = drive.isSolidState {
            rows.append(DiskDetailRow(L10n.string("Drive type"),
                                      solid ? L10n.string("Solid-state drive") : L10n.string("Hard disk drive")))
        }
        if let interconnect = drive.interconnect {
            rows.append(DiskDetailRow(L10n.string("Connection"), interconnect))
        }
        if let firmware = drive.firmware { rows.append(DiskDetailRow(L10n.string("Firmware"), firmware)) }
        return rows
    }
}
