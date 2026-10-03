import Darwin
import Foundation

/// The `vm_statistics64` fields the memory detail page (#27) uses. Page counts
/// are a snapshot; the event counters (page-ins, swap-outs, …) count pages since boot.
struct VMCounters: Equatable {
    var pageSize: UInt64
    var freePages: UInt64 = 0
    var speculativePages: UInt64 = 0
    var wiredPages: UInt64 = 0
    var compressorPages: UInt64 = 0
    var internalPages: UInt64 = 0
    var externalPages: UInt64 = 0
    var purgeablePages: UInt64 = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0
    var compressions: UInt64 = 0
    var decompressions: UInt64 = 0
}

extension VMCounters {
    init(_ stats: vm_statistics64_data_t, pageSize: UInt64) {
        self.init(pageSize: pageSize,
                  freePages: UInt64(stats.free_count),
                  speculativePages: UInt64(stats.speculative_count),
                  wiredPages: UInt64(stats.wire_count),
                  compressorPages: UInt64(stats.compressor_page_count),
                  internalPages: UInt64(stats.internal_page_count),
                  externalPages: UInt64(stats.external_page_count),
                  purgeablePages: UInt64(stats.purgeable_count),
                  pageIns: stats.pageins,
                  pageOuts: stats.pageouts,
                  swapIns: stats.swapins,
                  swapOuts: stats.swapouts,
                  compressions: stats.compressions,
                  decompressions: stats.decompressions)
    }
}

/// Physical memory split the way Activity Monitor's Memory tab splits it. Formulas,
/// all in pages × page size:
///
/// - App memory = internal − purgeable. Anonymous (not file-backed) pages of
///   processes, less the purgeable ones an app has said may be dropped.
/// - Wired = wire_count. Locked by the kernel; can never be compressed or paged out.
/// - Compressed = compressor_page_count. The physical pages the compressor occupies,
///   not the larger uncompressed size of what it holds.
/// - Cached files = external + purgeable. File-backed pages plus purgeable ones:
///   memory macOS can reclaim at once when an app needs it.
/// - Free = free − speculative. `free_count` includes speculative read-ahead pages,
///   which `external_page_count` already counts, so they are taken out here.
///
/// The five do not quite add up to physical memory: a few hundred MB (firmware,
/// GPU carve-outs, pages in transit) are in none of the kernel's queues.
struct MemoryBreakdown: Equatable {
    enum Category: CaseIterable {
        case app, wired, compressed, cached, free
    }

    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let free: UInt64
    /// Physical memory, bytes.
    let total: UInt64

    func bytes(_ category: Category) -> UInt64 {
        switch category {
        case .app: return app
        case .wired: return wired
        case .compressed: return compressed
        case .cached: return cached
        case .free: return free
        }
    }

    /// Share of the bar, 0...1. Scaled to physical memory, or to the sum if the
    /// counts ever overshoot it, so the bar never overflows.
    func fraction(_ category: Category) -> Double {
        let sum = Category.allCases.reduce(UInt64(0)) { $0 &+ bytes($1) }
        let scale = max(total, sum)
        return scale > 0 ? Double(bytes(category)) / Double(scale) : 0
    }

    /// Nil without a physical memory size to scale against.
    static func make(_ c: VMCounters, total: UInt64) -> MemoryBreakdown? {
        guard total > 0, c.pageSize > 0 else { return nil }
        func bytes(_ pages: UInt64) -> UInt64 { pages.multipliedReportingOverflow(by: c.pageSize).partialValue }
        func minus(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }
        return MemoryBreakdown(app: bytes(minus(c.internalPages, c.purgeablePages)),
                               wired: bytes(c.wiredPages),
                               compressed: bytes(c.compressorPages),
                               cached: bytes(c.externalPages &+ c.purgeablePages),
                               free: bytes(minus(c.freePages, c.speculativePages)),
                               total: total)
    }
}

/// The kernel's memory pressure level (`kern.memorystatus_vm_pressure_level`), the
/// same reading that colors Activity Monitor's pressure graph. The kernel moves
/// between levels when the count of available pages crosses its own thresholds;
/// MacStats applies no thresholds of its own. Raw values are the kernel's
/// (`DISPATCH_MEMORYPRESSURE_NORMAL` / `_WARN` / `_CRITICAL`).
enum MemoryPressureLevel: Int32, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    init?(kernelValue: Int32) {
        self.init(rawValue: kernelValue)
    }

    /// 0 / 1 / 2: what the history series stores, so the values are evenly spaced.
    var severity: Double {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    init?(severity: Double) {
        guard let level = Self.allCases.first(where: { $0.severity == severity.rounded() }) else { return nil }
        self = level
    }
}

/// `vm.swapusage`. A total of 0 means macOS has not created a swap file yet.
struct SwapUsage: Equatable {
    let used: UInt64
    let total: UInt64

    init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }

    init(_ usage: xsw_usage) {
        self.init(used: usage.xsu_used, total: usage.xsu_total)
    }
}

/// Paging activity between two `VMCounters`, in bytes per second (pages × page size
/// ÷ elapsed seconds). A counter that went backwards gives nil for that rate only.
struct PagingRates: Equatable {
    var pageIns: Double?
    var pageOuts: Double?
    var swapIns: Double?
    var swapOuts: Double?
    var compressions: Double?
    var decompressions: Double?

    /// Nil when no time passed or the page size changed between the two reads.
    static func make(previous: VMCounters, current: VMCounters, elapsed: TimeInterval) -> PagingRates? {
        guard elapsed > 0, elapsed.isFinite, previous.pageSize == current.pageSize else { return nil }
        let pageSize = Double(current.pageSize)
        func rate(_ counter: KeyPath<VMCounters, UInt64>) -> Double? {
            let before = previous[keyPath: counter], after = current[keyPath: counter]
            guard after >= before else { return nil }
            return Double(after - before) * pageSize / elapsed
        }
        return PagingRates(pageIns: rate(\.pageIns),
                           pageOuts: rate(\.pageOuts),
                           swapIns: rate(\.swapIns),
                           swapOuts: rate(\.swapOuts),
                           compressions: rate(\.compressions),
                           decompressions: rate(\.decompressions))
    }
}

/// Everything one detail sample shows. Each part is nil when its query failed,
/// so the page hides it instead of showing zeros.
struct MemoryDetail: Equatable {
    var breakdown: MemoryBreakdown?
    var level: MemoryPressureLevel?
    var swap: SwapUsage?
    /// Nil on the first sample (no baseline yet).
    var rates: PagingRates?
    /// Bytes; nil when the VM query failed.
    var pageSize: UInt64?
    /// Bytes; nil when unknown.
    var physicalMemory: UInt64?
}

/// The system calls behind `MemoryDetail`, injectable for tests.
protocol MemoryDetailSource {
    var physicalMemory: UInt64 { get }
    func counters() -> VMCounters?
    /// The raw `kern.memorystatus_vm_pressure_level` value.
    func pressureLevel() -> Int32?
    func swapUsage() -> SwapUsage?
}

struct SystemMemoryDetailSource: MemoryDetailSource {
    var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    func counters() -> VMCounters? {
        MemoryMetrics.vmStatistics().map { VMCounters($0, pageSize: MemoryMetrics.pageSize) }
    }

    func pressureLevel() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(usage)
    }
}

/// Samples `MemoryDetail` while the memory page is visible: one VM statistics read
/// and two sysctls per tick on a utility queue, delivered on the main queue. The
/// first reading is delivered right away (without rates), then one per interval.
///
/// Cost, measured by `MemoryDetailSamplerTests.testLiveSampleCost` on an Apple M5:
/// about 3 µs of CPU per sample in a debug build, i.e. under 0.001 % of one core at 2 s.
final class MemoryDetailSampler {
    static let defaultInterval: TimeInterval = 2

    private let source: MemoryDetailSource
    private let now: () -> UInt64

    private let queue = DispatchQueue(label: "com.macstats.MemoryDetailSampler", qos: .utility)
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a reading taken just before `stop` is never delivered.
    private var generation = 0

    /// Only touched on `queue`.
    private var previous: (counters: VMCounters, time: UInt64)?

    /// `source` and `now` (nanoseconds, monotonic) are injectable for tests.
    init(source: MemoryDetailSource = SystemMemoryDetailSource(),
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.source = source
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

    /// Idempotent: a second call while running is a no-op. `interval` is clamped to 0.5...60 s.
    func start(interval: TimeInterval = defaultInterval, onUpdate: @escaping (MemoryDetail) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : Self.defaultInterval

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(Int(period * 1000)), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let detail = self.tick()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(detail)
            }
        }
        timer = source
        source.resume()
    }

    /// Stops sampling and drops the baseline, so a later `start` does not report
    /// the idle gap as one interval.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        generation += 1
        lock.unlock()

        queue.async { [weak self] in self?.previous = nil }
    }

    /// Takes one sample synchronously, bypassing the timer. For tests and cost measurement.
    func sampleNow() -> MemoryDetail {
        queue.sync { tick() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    /// On `queue`.
    private func tick() -> MemoryDetail {
        let time = now()
        let counters = source.counters()
        let physical = source.physicalMemory
        var detail = MemoryDetail(level: source.pressureLevel().flatMap(MemoryPressureLevel.init(kernelValue:)),
                                  swap: source.swapUsage(),
                                  physicalMemory: physical > 0 ? physical : nil)
        if let counters {
            detail.breakdown = MemoryBreakdown.make(counters, total: physical)
            detail.pageSize = counters.pageSize > 0 ? counters.pageSize : nil
            if let last = previous, time > last.time {
                detail.rates = PagingRates.make(previous: last.counters, current: counters,
                                                elapsed: Double(time - last.time) / 1_000_000_000)
            }
            previous = (counters, time)
        } else {
            // A failed read breaks the chain; rates resume one interval after the next good one.
            previous = nil
        }
        return detail
    }
}
