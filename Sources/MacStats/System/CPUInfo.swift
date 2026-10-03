import Darwin
import Foundation

/// The `sysctl` values the CPU page reads, injectable so the topology rules can be
/// tested with any Mac's numbers.
protocol SysctlReading {
    func string(_ name: String) -> String?
    func int(_ name: String) -> Int?
    /// `kern.boottime`.
    func bootTime() -> Date?
}

/// Public `sysctlbyname` / `sysctl` only.
struct LiveSysctlReader: SysctlReading {
    func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func int(_ name: String) -> Int? {
        // The CPU counts are 32-bit; reading into a zeroed 64-bit value covers both widths.
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size || size == MemoryLayout<Int64>.size else { return nil }
        return Int(value)
    }

    func bootTime() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }
}

/// A set of logical CPUs of one kind, e.g. the Performance cores.
struct CPUCoreGroup: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Intel, or a Mac whose perf levels could not be read: every core in one group.
        case all
        /// An Apple-silicon perf level; 0 is the fastest. `name` is macOS's own
        /// (`hw.perflevelN.name`: "Performance", "Efficiency", "Super" on M5).
        case perfLevel(Int, name: String?)
    }

    let kind: Kind
    /// Indices into the per-core load array (`host_processor_info` order).
    let cores: Range<Int>

    var id: Int {
        if case .perfLevel(let level, _) = kind { return level }
        return -1
    }
}

/// What the CPU page shows about the chip itself. Read once per page visit.
struct CPUInfo: Equatable {
    /// `machdep.cpu.brand_string`, e.g. "Apple M5"; nil when macOS does not say.
    let chipName: String?
    let logicalCores: Int
    /// Fastest perf level first. One `.all` group on Intel.
    let groups: [CPUCoreGroup]
    let bootTime: Date?

    static func read(from sysctl: SysctlReading = LiveSysctlReader()) -> CPUInfo {
        let logical = sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levelCount = sysctl.int("hw.nperflevels") ?? 0
        let levels = (0..<max(levelCount, 0)).map { level in
            (logicalCores: sysctl.int("hw.perflevel\(level).logicalcpu") ?? 0,
             name: sysctl.string("hw.perflevel\(level).name"))
        }
        return CPUInfo(chipName: sysctl.string("machdep.cpu.brand_string"),
                       logicalCores: logical,
                       groups: groups(levels: levels, logicalCores: logical),
                       bootTime: sysctl.bootTime())
    }

    /// Splits `logicalCores` into perf levels. Apple silicon numbers its CPUs from the
    /// slowest cluster up (on an M1, CPUs 0–3 are Efficiency and 4–7 Performance), so
    /// level 0, the fastest, owns the highest indices. Anything that does not add up —
    /// one level (Intel), missing counts — becomes a single group rather than a guess.
    static func groups(levels: [(logicalCores: Int, name: String?)], logicalCores: Int) -> [CPUCoreGroup] {
        let single = logicalCores > 0 ? [CPUCoreGroup(kind: .all, cores: 0..<logicalCores)] : []
        guard levels.count > 1, levels.allSatisfy({ $0.logicalCores > 0 }),
              levels.reduce(0, { $0 + $1.logicalCores }) == logicalCores else { return single }

        var groups: [CPUCoreGroup] = []
        var end = logicalCores
        for (level, info) in levels.enumerated() {
            groups.append(CPUCoreGroup(kind: .perfLevel(level, name: info.name),
                                       cores: (end - info.logicalCores)..<end))
            end -= info.logicalCores
        }
        return groups
    }
}

/// `getloadavg`: runnable plus waiting threads, averaged over 1, 5 and 15 minutes.
struct CPULoadAverage: Equatable {
    let one: Double
    let five: Double
    let fifteen: Double

    static func read() -> CPULoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, 3)
        return make(values: values, count: count)
    }

    /// Nil unless all three averages came back and are sane.
    static func make(values: [Double], count: Int32) -> CPULoadAverage? {
        guard count == 3, values.count >= 3, values.prefix(3).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }
        return CPULoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }
}
