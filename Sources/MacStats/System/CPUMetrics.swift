import Darwin
import Foundation

struct CPUSample {
    let total: Double   // 0...100
    let user: Double    // 0...100, includes nice
    let system: Double  // 0...100
}

/// CPU load from host_processor_info(PROCESSOR_CPU_LOAD_INFO): cumulative per-core tick
/// counters diffed between samples. Limitation: the first sample has no baseline and
/// returns nil; ticks are 32-bit and wrap, which the &- deltas absorb.
final class CPUMetrics {

    /// Each mach_host_self() call adds a send-right reference that is never released,
    /// so the port is fetched once rather than on every tick.
    private let host = mach_host_self()
    private var previousTicks: [UInt32]?
    private(set) var coreCount: Int = 0

    /// Returns nil on the first call, on a core-count change, or when the mach call fails.
    func sample() -> CPUSample? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(host,
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount,
                                         &info,
                                         &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        coreCount = Int(cpuCount)
        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount) * states
        guard count > 0, Int(infoCount) >= count else { return nil }

        var ticks = [UInt32](repeating: 0, count: count)
        for i in 0..<count { ticks[i] = UInt32(bitPattern: info[i]) }
        return update(ticks: ticks, coreCount: Int(cpuCount))
    }

    /// Stores `ticks` as the new baseline and returns the load since the previous one.
    /// Nil when there is no baseline yet or the core count changed.
    func update(ticks: [UInt32], coreCount: Int) -> CPUSample? {
        guard let previous = previousTicks, previous.count == ticks.count else {
            previousTicks = ticks
            return nil
        }
        previousTicks = ticks
        return Self.usage(previous: previous, current: ticks, coreCount: coreCount)
    }

    /// Load between two per-core tick snapshots laid out as `coreCount` × `CPU_STATE_MAX`.
    /// Nil when no ticks elapsed.
    static func usage(previous: [UInt32], current: [UInt32], coreCount: Int) -> CPUSample? {
        let states = Int(CPU_STATE_MAX)
        guard coreCount > 0, previous.count >= coreCount * states, current.count >= coreCount * states else { return nil }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for core in 0..<coreCount {
            let base = core * states
            user   += UInt64(current[base + Int(CPU_STATE_USER)]   &- previous[base + Int(CPU_STATE_USER)])
            system += UInt64(current[base + Int(CPU_STATE_SYSTEM)] &- previous[base + Int(CPU_STATE_SYSTEM)])
            idle   += UInt64(current[base + Int(CPU_STATE_IDLE)]   &- previous[base + Int(CPU_STATE_IDLE)])
            nice   += UInt64(current[base + Int(CPU_STATE_NICE)]   &- previous[base + Int(CPU_STATE_NICE)])
        }

        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let scale = 100.0 / Double(total)
        return CPUSample(total: min(100, Double(user + system + nice) * scale),
                         user: min(100, Double(user + nice) * scale),
                         system: min(100, Double(system) * scale))
    }

    func reset() {
        previousTicks = nil
    }
}
