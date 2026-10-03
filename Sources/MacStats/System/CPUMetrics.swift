import Darwin
import Foundation

struct CPUSample: Equatable {
    let total: Double   // 0...100
    let user: Double    // 0...100, includes nice
    let system: Double  // 0...100
}

/// CPU load from host_processor_info(PROCESSOR_CPU_LOAD_INFO): cumulative per-core tick
/// counters diffed between samples. Limitation: the first sample has no baseline and
/// returns nil; ticks are 32-bit and wrap, which the &- deltas absorb.
///
/// An instance keeps one baseline, so use it through either `sample()` (pooled, for the
/// engine) or `sampleCores()` (per core, for the CPU detail page), not both.
final class CPUMetrics {

    /// Each mach_host_self() call adds a send-right reference that is never released,
    /// so the port is fetched once rather than on every tick.
    private let host = mach_host_self()
    private var previousTicks: [UInt32]?
    private(set) var coreCount: Int = 0

    /// Returns nil on the first call, on a core-count change, or when the mach call fails.
    func sample() -> CPUSample? {
        guard let reading = Self.readTicks(host: host) else { return nil }
        coreCount = reading.coreCount
        return update(ticks: reading.ticks, coreCount: reading.coreCount)
    }

    /// Per-core load since the previous call, in logical-CPU order. Same nil rules as
    /// `sample()`; an element is nil for a core that reported no ticks in between.
    func sampleCores() -> [CPUSample?]? {
        guard let reading = Self.readTicks(host: host) else { return nil }
        coreCount = reading.coreCount
        return updateCores(ticks: reading.ticks, coreCount: reading.coreCount)
    }

    /// The raw counters: `coreCount` × `CPU_STATE_MAX` ticks. Nil when the mach call fails.
    static func readTicks(host: host_t) -> (ticks: [UInt32], coreCount: Int)? {
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

        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount) * states
        guard count > 0, Int(infoCount) >= count else { return nil }

        var ticks = [UInt32](repeating: 0, count: count)
        for i in 0..<count { ticks[i] = UInt32(bitPattern: info[i]) }
        return (ticks, Int(cpuCount))
    }

    /// Stores `ticks` as the new baseline and returns the load since the previous one.
    /// Nil when there is no baseline yet or the core count changed.
    func update(ticks: [UInt32], coreCount: Int) -> CPUSample? {
        guard let previous = swapBaseline(ticks) else { return nil }
        return Self.usage(previous: previous, current: ticks, coreCount: coreCount)
    }

    /// `update(ticks:coreCount:)`, per core.
    func updateCores(ticks: [UInt32], coreCount: Int) -> [CPUSample?]? {
        guard let previous = swapBaseline(ticks) else { return nil }
        return Self.coreUsages(previous: previous, current: ticks, coreCount: coreCount)
    }

    /// Installs `ticks` as the baseline and returns the old one when it is comparable.
    private func swapBaseline(_ ticks: [UInt32]) -> [UInt32]? {
        defer { previousTicks = ticks }
        guard let previous = previousTicks, previous.count == ticks.count else { return nil }
        return previous
    }

    /// Load between two per-core tick snapshots laid out as `coreCount` × `CPU_STATE_MAX`.
    /// Nil when no ticks elapsed.
    static func usage(previous: [UInt32], current: [UInt32], coreCount: Int) -> CPUSample? {
        guard isValid(previous: previous, current: current, coreCount: coreCount) else { return nil }
        var pooled = TickDelta()
        for core in 0..<coreCount {
            pooled.add(TickDelta(previous: previous, current: current, core: core))
        }
        return pooled.load
    }

    /// One load per core, in logical-CPU order; nil for a core with no elapsed ticks.
    /// Empty when the snapshots do not match `coreCount`.
    static func coreUsages(previous: [UInt32], current: [UInt32], coreCount: Int) -> [CPUSample?] {
        guard isValid(previous: previous, current: current, coreCount: coreCount) else { return [] }
        return (0..<coreCount).map { TickDelta(previous: previous, current: current, core: $0).load }
    }

    private static func isValid(previous: [UInt32], current: [UInt32], coreCount: Int) -> Bool {
        let states = Int(CPU_STATE_MAX)
        return coreCount > 0 && previous.count >= coreCount * states && current.count >= coreCount * states
    }

    /// Ticks spent in each state between two snapshots, for one core or summed over several.
    private struct TickDelta {
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0

        init() {}

        init(previous: [UInt32], current: [UInt32], core: Int) {
            let base = core * Int(CPU_STATE_MAX)
            func delta(_ state: Int32) -> UInt64 {
                UInt64(current[base + Int(state)] &- previous[base + Int(state)])
            }
            user = delta(CPU_STATE_USER)
            system = delta(CPU_STATE_SYSTEM)
            idle = delta(CPU_STATE_IDLE)
            nice = delta(CPU_STATE_NICE)
        }

        mutating func add(_ other: TickDelta) {
            user += other.user
            system += other.system
            idle += other.idle
            nice += other.nice
        }

        var load: CPUSample? {
            let total = user + system + idle + nice
            guard total > 0 else { return nil }
            let scale = 100.0 / Double(total)
            return CPUSample(total: min(100, Double(user + system + nice) * scale),
                             user: min(100, Double(user + nice) * scale),
                             system: min(100, Double(system) * scale))
        }
    }

    func reset() {
        previousTicks = nil
    }
}
