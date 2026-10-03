import Foundation
import IOKit

/// Cumulative I/O of the physical drives since each was attached (since startup for
/// the internal drive).
struct DiskIOCounters: Equatable {
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var readOperations: UInt64 = 0
    var writeOperations: UInt64 = 0
}

/// Throughput between two `DiskIOCounters` readings.
struct DiskIORates: Equatable {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let readOperationsPerSecond: Double
    let writeOperationsPerSecond: Double
}

/// What the Disk page's activity section shows. `rates` is nil until there are two
/// readings, so the first update only carries the totals.
struct DiskActivityReport: Equatable {
    let totals: DiskIOCounters
    let rates: DiskIORates?
}

/// Parses the "Statistics" dictionary of IOBlockStorageDriver services, as the
/// pre-0.2 `DiskMetrics` did, and turns two readings into rates.
enum DiskIOStatistics {
    /// One driver's statistics and the "Physical Interconnect" of the device under it.
    struct Driver {
        let statistics: [String: Any]
        let interconnect: String?
    }

    /// Disk images ("Virtual Interface") are left out: their I/O also reaches the
    /// drive holding the image file, so counting them would count it twice.
    static let virtualInterconnect = "Virtual Interface"

    /// Sum over physical drives. Nil when no driver reports any statistics, so the
    /// page shows "not available" instead of a flat zero line.
    static func sum(_ drivers: [Driver]) -> DiskIOCounters? {
        var total = DiskIOCounters()
        var found = false
        for driver in drivers where driver.interconnect != virtualInterconnect {
            guard let counters = counters(from: driver.statistics) else { continue }
            found = true
            total.readBytes &+= counters.readBytes
            total.writeBytes &+= counters.writeBytes
            total.readOperations &+= counters.readOperations
            total.writeOperations &+= counters.writeOperations
        }
        return found ? total : nil
    }

    /// Nil when the dictionary has none of the byte counters; a missing operations
    /// counter counts as 0.
    static func counters(from statistics: [String: Any]) -> DiskIOCounters? {
        func value(_ key: String) -> UInt64? { (statistics[key] as? NSNumber)?.uint64Value }
        let read = value("Bytes (Read)"), written = value("Bytes (Write)")
        guard read != nil || written != nil else { return nil }
        return DiskIOCounters(readBytes: read ?? 0,
                              writeBytes: written ?? 0,
                              readOperations: value("Operations (Read)") ?? 0,
                              writeOperations: value("Operations (Write)") ?? 0)
    }

    /// Rates over `elapsed` seconds. Counters are cumulative, but drives come and go
    /// (an external disk ejected), so a counter that shrank reads as no traffic rather
    /// than a negative rate. Nil without a positive, finite interval.
    static func rates(from previous: DiskIOCounters, to current: DiskIOCounters,
                      elapsed: TimeInterval) -> DiskIORates? {
        guard elapsed > 0, elapsed.isFinite else { return nil }
        func rate(_ before: UInt64, _ after: UInt64) -> Double {
            after >= before ? Double(after - before) / elapsed : 0
        }
        return DiskIORates(readBytesPerSecond: rate(previous.readBytes, current.readBytes),
                           writeBytesPerSecond: rate(previous.writeBytes, current.writeBytes),
                           readOperationsPerSecond: rate(previous.readOperations, current.readOperations),
                           writeOperationsPerSecond: rate(previous.writeOperations, current.writeOperations))
    }

    /// Reads every IOBlockStorageDriver. About 0.1 ms of CPU per call.
    static func readCounters() -> DiskIOCounters? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var drivers: [Driver] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                                   kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            // The driver's provider is the block storage device that names its interconnect.
            var device: io_registry_entry_t = 0
            var interconnect: String?
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &device) == KERN_SUCCESS {
                let protocolInfo = IORegistryEntryCreateCFProperty(device, "Protocol Characteristics" as CFString,
                                                                   kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                interconnect = protocolInfo?["Physical Interconnect"] as? String
                IOObjectRelease(device)
            }
            drivers.append(Driver(statistics: statistics, interconnect: interconnect))
        }
        return sum(drivers)
    }
}

/// Disk throughput for the Disk page only: runs while the page is visible
/// (`start` in `onAppear`, `stop` in `onDisappear`), samples on a utility queue and
/// delivers on the main queue — the totals at once, then rates every `interval`.
///
/// Cost: one sample reads ~10 registry entries, about 0.1 ms of CPU on an Apple M5
/// (release build), i.e. ~0.01 % of one core at the 1 s interval.
final class DiskActivitySampler {

    private let readCounters: () -> DiskIOCounters?
    private let now: () -> UInt64
    private let queue = DispatchQueue(label: "com.macstats.DiskActivitySampler", qos: .utility)
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a report taken just before `stop` is never delivered.
    private var generation = 0
    // Only touched on `queue`.
    private var previous: (counters: DiskIOCounters, time: UInt64)?

    /// `readCounters` and `now` (nanoseconds, monotonic) are injectable for tests.
    init(readCounters: @escaping () -> DiskIOCounters? = DiskIOStatistics.readCounters,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.readCounters = readCounters
        self.now = now
    }

    deinit {
        timer?.cancel()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    /// Idempotent while running. `onUpdate` gets nil when the counters cannot be read.
    /// `interval` is clamped to 0.5...60 s.
    func start(interval: TimeInterval = 1, onUpdate: @escaping (DiskActivityReport?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : 1

        let source = DispatchSource.makeTimerSource(queue: queue)
        // Fires at once for the baseline (totals only), then every period.
        source.schedule(deadline: .now(), repeating: .milliseconds(Int(period * 1000)),
                        leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let report = self.tick()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(report)
            }
        }
        timer = source
        source.resume()
    }

    /// Stops sampling and drops the baseline, so a later `start` does not report the
    /// time the page was closed as one interval.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        generation += 1
        lock.unlock()
        queue.async { [weak self] in self?.previous = nil }
    }

    /// One sample, synchronously. For tests.
    func sampleNow() -> DiskActivityReport? {
        queue.sync { tick() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    /// On `queue`.
    private func tick() -> DiskActivityReport? {
        let time = now()
        guard let counters = readCounters() else {
            previous = nil
            return nil
        }
        defer { previous = (counters, time) }
        let rates = previous.flatMap { last in
            time > last.time
                ? DiskIOStatistics.rates(from: last.counters, to: counters,
                                         elapsed: Double(time - last.time) / 1_000_000_000)
                : nil
        }
        return DiskActivityReport(totals: counters, rates: rates)
    }
}
