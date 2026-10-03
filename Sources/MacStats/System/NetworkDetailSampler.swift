import Foundation
import Network

/// One counted interface on the Network page.
struct NetworkInterfaceDetail: Identifiable, Equatable {
    let name: String
    let kind: NetworkInterfaceKind
    let isPrimary: Bool
    /// Bytes per second over the last interval; nil before a baseline or after the
    /// interface was re-created.
    var downRate: Double?
    var upRate: Double?
    /// The interface's own counters (since it came up, normally since boot).
    var sinceBoot: NetworkTrafficLedger.Totals?
    var sinceStart: NetworkTrafficLedger.Totals?
    var addresses = InterfaceAddresses()
    /// Bits per second, Ethernet only, when the driver reports one.
    var linkSpeed: UInt64?

    var id: String { name }
}

/// Everything the Network page shows below the chart.
struct NetworkDetailReport: Equatable {
    var interfaces: [NetworkInterfaceDetail] = []
    /// Summed over counted interfaces, including any that have gone away since.
    var sinceStart: NetworkTrafficLedger.Totals?
    /// Summed over the counted interfaces present now.
    var sinceBoot: NetworkTrafficLedger.Totals?
    var wifi: WiFiDetails?

    /// Lists the counted interfaces that are in use — on the current path or holding an
    /// address — primary first, then in the system's preference order, then by name.
    /// Idle ports (the Thunderbolt `en1`…`en4` a Mac always has) are left out.
    static func make(counters: [InterfaceCounters]?,
                     previous: [String: InterfaceCounters]?,
                     elapsed: TimeInterval?,
                     addresses: [String: InterfaceAddresses],
                     path: NetworkPathSummary,
                     wifi: WiFiDetails.Raw?,
                     session: [String: NetworkTrafficLedger.Totals]?) -> NetworkDetailReport {
        let counted = (counters ?? []).filter { NetworkMetrics.countsTraffic(of: $0.name) }
        let byName = Dictionary(counted.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let primary = path.primaryInterface
        let pathOrder = Dictionary(path.interfaces.enumerated().map { ($1.name, $0) },
                                   uniquingKeysWith: { first, _ in first })

        var names = Set(path.interfaces.map(\.name))
        names.formUnion(addresses.filter { !$0.value.isEmpty }.map(\.key))
        names = names.filter { NetworkMetrics.countsTraffic(of: $0) }

        let interfaces = names.map { name -> NetworkInterfaceDetail in
            let kind = path.kind(of: name) ?? (wifi?.interface == name ? .wifi : .other)
            var detail = NetworkInterfaceDetail(name: name, kind: kind, isPrimary: name == primary)
            if let now = byName[name] {
                detail.sinceBoot = NetworkTrafficLedger.Totals(inputBytes: now.inputBytes, outputBytes: now.outputBytes)
                if let before = previous?[name], let elapsed, elapsed > 0,
                   now.inputBytes >= before.inputBytes, now.outputBytes >= before.outputBytes {
                    detail.downRate = Double(now.inputBytes - before.inputBytes) / elapsed
                    detail.upRate = Double(now.outputBytes - before.outputBytes) / elapsed
                }
                if kind == .ethernet, now.linkSpeed > 0 { detail.linkSpeed = now.linkSpeed }
            }
            if let session { detail.sinceStart = session[name] ?? NetworkTrafficLedger.Totals() }
            detail.addresses = addresses[name] ?? InterfaceAddresses()
            return detail
        }.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            let left = pathOrder[lhs.name] ?? .max, right = pathOrder[rhs.name] ?? .max
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var report = NetworkDetailReport(interfaces: interfaces, wifi: wifi.flatMap(WiFiDetails.make))
        if counters != nil {
            report.sinceBoot = counted.reduce(into: NetworkTrafficLedger.Totals()) { sum, interface in
                sum.inputBytes &+= interface.inputBytes
                sum.outputBytes &+= interface.outputBytes
            }
        }
        report.sinceStart = session.map { totals in
            totals.values.reduce(into: NetworkTrafficLedger.Totals()) { sum, interface in
                sum.inputBytes &+= interface.inputBytes
                sum.outputBytes &+= interface.outputBytes
            }
        }
        return report
    }
}

/// The Network page's sampler: per-interface counters and rates, addresses, Wi-Fi radio
/// details, and the system's path (`NWPathMonitor`) for the primary interface. Like
/// `ProcessSampler` it runs only while the page is visible: `start` in `onAppear`,
/// `stop` in `onDisappear`. Work happens on a utility queue; reports arrive on main —
/// one right away (no rates yet), then one per interval, plus one whenever the path changes.
///
/// Each reading also feeds `NetworkTrafficLedger.shared`, so the session totals are
/// current while the page is open.
///
/// Cost, measured by `NetworkDetailLiveTests.testLiveSampleAndCost` on an Apple M5 MacBook
/// (Wi-Fi associated): 0.4–0.6 ms of MacStats' CPU and about 4 ms of wall time per sample,
/// the wait being CoreWLAN's round trips to the Wi-Fi daemon — under 0.03 % of one core at
/// the 2 s interval. Creating the CoreWLAN client costs about 16 ms once per page visit.
final class NetworkDetailSampler {

    private let readCounters: () -> [InterfaceCounters]?
    private let readAddresses: () -> [InterfaceAddresses.Raw]
    private let readWiFi: () -> WiFiDetails.Raw?
    private let ledger: NetworkTrafficLedger?
    private let now: () -> UInt64

    private let queue = DispatchQueue(label: "com.macstats.NetworkDetailSampler",
                                      qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Guards `timer`, `monitor` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var monitor: NWPathMonitor?
    /// Bumped by every start/stop so a report produced just before `stop` is never delivered.
    private var generation = 0

    // Only touched on `queue`.
    private var previous: (counters: [String: InterfaceCounters], time: UInt64)?
    private var path = NetworkPathSummary()
    /// The last tick's readings, re-used when only the path changed.
    private var lastCounters: [InterfaceCounters]?
    private var lastPrevious: [String: InterfaceCounters]?
    private var lastElapsed: TimeInterval?
    private var lastWiFi: WiFiDetails.Raw?

    /// All readers are injectable for tests; `now` is monotonic nanoseconds.
    init(readCounters: @escaping () -> [InterfaceCounters]? = NetworkMetrics.readInterfaceCounters,
         readAddresses: @escaping () -> [InterfaceAddresses.Raw] = InterfaceAddresses.readRaw,
         readWiFi: (() -> WiFiDetails.Raw?)? = nil,
         ledger: NetworkTrafficLedger? = .shared,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.readCounters = readCounters
        self.readAddresses = readAddresses
        if let readWiFi {
            self.readWiFi = readWiFi
        } else {
            let reader = WiFiReader()
            self.readWiFi = { reader.read() }
        }
        self.ledger = ledger
        self.now = now
    }

    deinit {
        timer?.cancel()
        monitor?.cancel()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    /// Idempotent: a second call while running is a no-op. `interval` is clamped to 0.5...60 s.
    func start(interval: TimeInterval = 2, onUpdate: @escaping (NetworkDetailReport) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : 2

        let deliver: (NetworkDetailReport) -> Void = { [weak self] report in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(report)
            }
        }

        // A monitor cannot be restarted once cancelled, so each start gets a new one.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.path = NetworkPathSummary(path)
            deliver(self.rebuild())
        }
        self.monitor = monitor
        monitor.start(queue: queue)

        queue.async { [weak self] in
            guard let self else { return }
            deliver(self.tick())
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + period,
                        repeating: .milliseconds(Int(period * 1000)),
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            deliver(self.tick())
        }
        timer = source
        source.resume()
    }

    /// Stops sampling and the path monitor, and drops the baseline so a later `start`
    /// does not report the idle gap as one interval.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        monitor?.cancel()
        monitor = nil
        generation += 1
        lock.unlock()

        queue.async { [weak self] in
            self?.previous = nil
            self?.lastPrevious = nil
            self?.lastElapsed = nil
        }
    }

    /// Takes one sample synchronously, bypassing the timer. For tests and cost measurement.
    func sampleNow() -> NetworkDetailReport {
        queue.sync { tick() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    // MARK: - Sampling (on `queue`)

    private func tick() -> NetworkDetailReport {
        let counters = readCounters()
        let time = now()
        if let counters { ledger?.record(counters) }

        lastPrevious = nil
        lastElapsed = nil
        if let counters {
            if let last = previous, time > last.time {
                lastPrevious = last.counters
                lastElapsed = Double(time - last.time) / 1_000_000_000
            }
            previous = (Dictionary(counters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }), time)
        }
        lastCounters = counters
        lastWiFi = readWiFi()
        return rebuild()
    }

    /// The report from the last readings, the current path and fresh addresses.
    private func rebuild() -> NetworkDetailReport {
        NetworkDetailReport.make(counters: lastCounters,
                                 previous: lastPrevious,
                                 elapsed: lastElapsed,
                                 addresses: InterfaceAddresses.make(readAddresses()),
                                 path: path,
                                 wifi: lastWiFi,
                                 session: ledger.flatMap { $0.hasBaseline ? $0.perInterface() : nil })
    }
}
