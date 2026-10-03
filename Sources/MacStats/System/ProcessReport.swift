import AppKit
import Darwin
import Foundation

/// One inspectable process at one instant, CPU time already in nanoseconds.
struct ProcessEntry {
    let pid: pid_t
    let startTime: UInt64
    let cpuNanoseconds: UInt64
    let footprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let identity: ProcessIdentity
}

/// Every process MacStats could read at one instant.
struct ProcessSnapshot {
    let entries: [pid_t: ProcessEntry]
    /// Processes listed but not readable (other users, protected processes).
    let skippedCount: Int
    let coreCount: Int
}

enum ProcessMetric {
    case cpu
    case memory
    case diskIO
}

/// One row: a standalone process, or an app with all its helpers summed.
struct ProcessUsage: Identifiable {
    /// The group bundle path, or "pid:<n>" for a standalone process.
    let id: String
    /// The app's main process when it is running, otherwise the lowest member PID.
    let pid: pid_t
    /// Every member, ascending.
    let pids: [pid_t]
    let name: String
    /// The app's icon; nil for non-app processes (pages draw a generic one).
    let icon: NSImage?
    /// 100 = one core fully busy; can exceed 100 on a multi-core Mac.
    let cpuPercent: Double
    /// Share of the whole machine, 0...100 (`cpuPercent / coreCount`).
    let cpuShareOfCapacity: Double
    let memoryBytes: UInt64
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    /// False when every member is new this interval, so CPU and disk rates are unknown
    /// (reported as 0). Memory is an instantaneous figure and always valid.
    let isMeasured: Bool

    var diskBytesPerSecond: Double { diskReadBytesPerSecond + diskWriteBytesPerSecond }

    func value(of metric: ProcessMetric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memoryBytes)
        case .diskIO: return diskBytesPerSecond
        }
    }
}

/// Per-process usage between two snapshots.
struct ProcessReport {
    /// Every row, ordered by `id`.
    let processes: [ProcessUsage]
    /// Processes MacStats is not allowed to inspect; pages say "Showing processes you can inspect".
    let skippedCount: Int
    let coreCount: Int

    /// The `count` heaviest rows for `metric`. Ties go to the name, then the PID, so rows
    /// with equal values do not swap places between refreshes. CPU and disk lists leave
    /// out rows that have no rate yet.
    func top(_ metric: ProcessMetric, count: Int = 5) -> [ProcessUsage] {
        guard count > 0 else { return [] }
        let candidates = metric == .memory ? processes : processes.filter(\.isMeasured)
        let sorted = candidates.sorted { lhs, rhs in
            let left = lhs.value(of: metric), right = rhs.value(of: metric)
            if left != right { return left > right }
            switch lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.pid < rhs.pid
            }
        }
        return Array(sorted.prefix(count))
    }

    /// Pure: rates over `elapsed` seconds. A process counts towards CPU and disk rates only
    /// if `previous` has the same PID with the same start time (a different start time
    /// means the PID was reused) and its counters did not go backwards. Exited processes
    /// simply drop out; new ones contribute memory but no rate.
    static func make(previous: ProcessSnapshot, current: ProcessSnapshot, elapsed: TimeInterval) -> ProcessReport {
        struct Group {
            var members: [ProcessEntry] = []
            var cpuNanoseconds: UInt64 = 0
            var readBytes: UInt64 = 0
            var writtenBytes: UInt64 = 0
            var footprintBytes: UInt64 = 0
            var isMeasured = false
        }

        let canMeasure = elapsed > 0 && elapsed.isFinite
        var groups: [String: Group] = [:]
        for entry in current.entries.values {
            let key = entry.identity.groupBundlePath ?? "pid:\(entry.pid)"
            var group = groups[key] ?? Group()
            group.members.append(entry)
            group.footprintBytes &+= entry.footprintBytes
            if canMeasure,
               let before = previous.entries[entry.pid],
               before.startTime == entry.startTime,
               entry.cpuNanoseconds >= before.cpuNanoseconds {
                group.isMeasured = true
                group.cpuNanoseconds &+= entry.cpuNanoseconds - before.cpuNanoseconds
                if entry.diskReadBytes >= before.diskReadBytes {
                    group.readBytes &+= entry.diskReadBytes - before.diskReadBytes
                }
                if entry.diskWrittenBytes >= before.diskWrittenBytes {
                    group.writtenBytes &+= entry.diskWrittenBytes - before.diskWrittenBytes
                }
            }
            groups[key] = group
        }

        let cores = current.coreCount
        let usages = groups.map { key, group -> ProcessUsage in
            let members = group.members.sorted { $0.pid < $1.pid }
            let bundle = members[0].identity.groupBundlePath
            // The app's own main process names the row, so the row reads "Google Chrome",
            // not whichever helper has the lowest PID.
            let leader = members.first { $0.identity.ownBundlePath == bundle && $0.identity.app != nil }
                ?? members.first { $0.identity.ownBundlePath == bundle && bundle != nil }
                ?? members[0]
            let name = leader.identity.app?.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? bundle.map(ProcessIdentity.displayName(ofBundle:))
                ?? leader.identity.name

            var cpuPercent = 0.0, read = 0.0, written = 0.0
            if group.isMeasured {
                cpuPercent = Double(group.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100
                if cores > 0 { cpuPercent = min(cpuPercent, Double(cores) * 100) }
                read = Double(group.readBytes) / elapsed
                written = Double(group.writtenBytes) / elapsed
            }
            return ProcessUsage(id: key,
                                pid: leader.pid,
                                pids: members.map(\.pid),
                                name: name,
                                icon: leader.identity.app?.icon,
                                cpuPercent: cpuPercent,
                                cpuShareOfCapacity: cores > 0 ? cpuPercent / Double(cores) : 0,
                                memoryBytes: group.footprintBytes,
                                diskReadBytesPerSecond: read,
                                diskWriteBytesPerSecond: written,
                                isMeasured: group.isMeasured)
        }
        return ProcessReport(processes: usages.sorted { $0.id < $1.id },
                             skippedCount: current.skippedCount,
                             coreCount: cores)
    }
}
