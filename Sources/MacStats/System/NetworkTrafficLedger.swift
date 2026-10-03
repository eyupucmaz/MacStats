import Foundation

/// Bytes moved since MacStats started, per counted interface (`NetworkMetrics.countsTraffic`).
///
/// "Started" is the first reading the ledger is given: the engine's `NetworkMetrics`
/// feeds `shared` and is primed at launch. Totals are built from the interfaces' own
/// 64-bit counters, not from the sampled rates, so time spent with sampling paused
/// (popover closed) is still counted when sampling resumes. The rules per reading:
/// - a counter that grew adds its growth;
/// - a counter that went backwards belongs to a re-created interface (an adapter
///   replugged) and adds its whole new value, which started from zero;
/// - an interface never seen before appeared after launch and adds its whole value.
/// The only bytes it can miss are those an interface moved between the last reading
/// and being re-created, which needs a replug during a sampling pause.
///
/// Thread-safe: the engine records on its sampler queue, the Network page on its own.
final class NetworkTrafficLedger {
    static let shared = NetworkTrafficLedger()

    struct Totals: Equatable {
        var inputBytes: UInt64 = 0
        var outputBytes: UInt64 = 0
    }

    private let lock = NSLock()
    /// Nil until the first reading, which is the baseline. Interfaces that disappear are
    /// kept, so one that comes back with its old counters is not counted twice.
    private var last: [String: InterfaceCounters]?
    private var totals: [String: Totals] = [:]

    init() {}

    /// Folds in one reading of every interface (uncounted ones are ignored).
    func record(_ counters: [InterfaceCounters]) {
        lock.lock()
        defer { lock.unlock() }
        let counted = counters.filter { NetworkMetrics.countsTraffic(of: $0.name) }
        guard var seen = last else {
            last = Dictionary(counted.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return
        }
        for now in counted {
            let before = seen[now.name]
            var total = totals[now.name] ?? Totals()
            total.inputBytes &+= Self.growth(from: before?.inputBytes, to: now.inputBytes)
            total.outputBytes &+= Self.growth(from: before?.outputBytes, to: now.outputBytes)
            totals[now.name] = total
            seen[now.name] = now
        }
        last = seen
    }

    /// Bytes added since the previous reading of one counter (see the rules above).
    static func growth(from before: UInt64?, to now: UInt64) -> UInt64 {
        guard let before, now >= before else { return now }
        return now - before
    }

    /// True once the baseline reading has been taken.
    var hasBaseline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return last != nil
    }

    /// Per-interface totals since the baseline; interfaces that moved nothing are included
    /// once seen after it. Empty before the second reading.
    func perInterface() -> [String: Totals] {
        lock.lock()
        defer { lock.unlock() }
        return totals
    }
}
