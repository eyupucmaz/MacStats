import Combine
import Foundation

/// Everything the UI draws, published as one value so a tick costs a single change
/// notification instead of one per field. Unavailable sensors carry a flag rather
/// than a fake zero.
struct StatsSnapshot: Equatable {
    var cpuUsage: Double = 0
    var gpuUsage: Double = 0
    var isGPUAvailable: Bool = false
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var diskUsedBytes: UInt64 = 0
    var diskTotalBytes: UInt64 = 0
    var networkDownBytes: Double = 0
    var networkUpBytes: Double = 0
    var batteryLevel: Int = 0
    var batteryState: String = "Unknown"
    var fanRPM: Int = 0
    var isFanAvailable: Bool = false
    var temperature: Double = 0
    var isTemperatureAvailable: Bool = false

    /// Desktops report level 0 / "AC Power"; a failed read reports "Unknown".
    var isBatteryAvailable: Bool { batteryLevel > 0 && batteryState != "Unknown" }

    /// Folds one reading in. Rate metrics without a baseline (nil) and a disk query
    /// that failed keep their previous value; sensors that read nil become unavailable.
    mutating func apply(_ reading: StatsReading) {
        if let cpu = reading.cpuUsage { cpuUsage = cpu }
        gpuUsage = reading.gpuUsage ?? 0
        isGPUAvailable = reading.gpuUsage != nil
        memoryUsed = reading.memoryUsed
        memoryTotal = reading.memoryTotal
        if let disk = reading.disk {
            diskUsedBytes = disk.usedBytes
            diskTotalBytes = disk.totalBytes
        }
        if let network = reading.network {
            networkDownBytes = network.downBytesPerSecond
            networkUpBytes = network.upBytesPerSecond
        }
        batteryLevel = reading.batteryLevel
        batteryState = reading.batteryState
        fanRPM = reading.fanRPM ?? 0
        isFanAvailable = reading.fanRPM != nil
        temperature = reading.temperature ?? 0
        isTemperatureAvailable = reading.temperature != nil
    }
}

/// One pass over the samplers. Optionals are readings that can be missing: rates
/// before a baseline exists, and sensors this Mac does not expose.
struct StatsReading {
    var cpuUsage: Double? = nil
    /// The user / system split of `cpuUsage`; recorded in history only.
    var cpuUser: Double? = nil
    var cpuSystem: Double? = nil
    var gpuUsage: Double? = nil
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    /// Recorded in history only.
    var memoryPressure: Double? = nil
    var disk: DiskSample? = nil
    var network: NetworkSample? = nil
    var batteryLevel: Int = 0
    var batteryState: String = "Unknown"
    var fanRPM: Int? = nil
    var temperature: Double? = nil
}

/// The hardware side of the engine, injectable so tests can drive it with fixed
/// readings. Only ever called on the engine's sampler queue.
protocol StatsSampler: AnyObject {
    /// Takes a first sample of the delta-based metrics so the next read has a baseline.
    func primeBaselines()
    /// Forgets the baselines so a read after a pause is not one huge delta.
    func resetBaselines()
    func read() -> StatsReading
}

final class LiveStatsSampler: StatsSampler {
    private let cpu = CPUMetrics()
    private let disk = DiskMetrics()
    private let network = NetworkMetrics()
    private let battery = BatteryMetrics()

    func primeBaselines() {
        _ = cpu.sample()
        _ = network.sample()
    }

    func resetBaselines() {
        cpu.reset()
        network.reset()
    }

    func read() -> StatsReading {
        let cpu = cpu.sample()
        let memory = MemoryMetrics.sample()
        let battery = battery.sample()
        return StatsReading(cpuUsage: cpu?.total,
                            cpuUser: cpu?.user,
                            cpuSystem: cpu?.system,
                            gpuUsage: GPUMetrics.sample(),
                            memoryUsed: memory.used,
                            memoryTotal: memory.total,
                            memoryPressure: memory.used > 0 ? memory.pressure : nil,
                            disk: disk.sample(),
                            network: network.sample(),
                            batteryLevel: battery.level,
                            batteryState: battery.state,
                            fanRPM: SMCService.shared.readFanRPM(),
                            temperature: SMCService.shared.readCPUTemperature())
    }
}

final class StatsEngine: ObservableObject {
    static let shared = StatsEngine()

    /// Replaced at most once per tick, and only when a value actually changed.
    @Published private(set) var snapshot = StatsSnapshot()

    /// The last hour of every core metric, appended on the main thread each time a
    /// tick is delivered. Read it (and observe its `revision`) from the main thread only.
    let history: MetricHistory

    /// `.workItem` drains autoreleased Foundation/IOKit objects after every tick
    /// instead of letting them pile up in the queue's pool.
    private let queue = DispatchQueue(label: "com.macstats.StatsEngine.sampler",
                                      qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Guards `timer`, `updateInterval`, `pendingSnapshot` and `pendingHistory`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var updateInterval: Double = 1.0

    private let sampler: StatsSampler
    /// The sampler-side copy that readings are folded into. Only touched on `queue`.
    private var latest = StatsSnapshot()
    /// Non-nil while a main-thread delivery is queued. Later ticks just replace it,
    /// so a stalled main thread gets one update when it wakes, not a backlog.
    private var pendingSnapshot: StatsSnapshot?
    /// Tick samples waiting for the main-thread delivery. Unlike snapshots they are
    /// not coalesced, so a briefly stalled main thread does not punch holes in history.
    private var pendingHistory: [CoreMetricSample] = []
    /// Bounds `pendingHistory` if the main thread stalls for long; older samples go.
    private static let maxPendingHistory = 64
    /// Stamps each tick's history sample. Injectable for tests.
    private let clock: () -> Date

    init(sampler: StatsSampler = LiveStatsSampler(), clock: @escaping () -> Date = Date.init) {
        // No sampling until start(); the timer is owned solely by start()/stop().
        self.sampler = sampler
        self.clock = clock
        history = MetricHistory(sampleInterval: updateInterval, clock: clock)
    }

    // MARK: - Lifecycle

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    /// Idempotent: a second call while running is a no-op.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        startTimerLocked()
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()

        // Drop the delta baselines so a later start() cannot report the whole idle gap as one tick.
        queue.async { [weak self] in
            guard let self else { return }
            self.sampler.resetBaselines()
            self.latest.cpuUsage = 0
            self.latest.gpuUsage = 0
            self.latest.networkDownBytes = 0
            self.latest.networkUpBytes = 0
            // Not a measurement, so nothing is recorded; the next sample after a
            // restart lands far enough away to be stored as a gap.
            self.publish(self.latest, historySample: nil)
        }
    }

    /// Restarts the timer with a new period, clamped to 0.5...60 seconds. An unchanged
    /// period is a no-op, so callers can re-apply the setting freely.
    func setUpdateInterval(_ seconds: Double) {
        let clamped = Self.normalizedUpdateInterval(seconds)
        lock.lock()
        defer { lock.unlock() }
        guard clamped != updateInterval else { return }
        updateInterval = clamped
        updateHistoryInterval(clamped)
        guard let running = timer else { return }
        running.cancel()
        timer = nil
        startTimerLocked()
    }

    /// `history` is main-thread only; settings call this on main, so this is normally direct.
    private func updateHistoryInterval(_ seconds: Double) {
        if Thread.isMainThread {
            history.setSampleInterval(seconds)
        } else {
            DispatchQueue.main.async { [weak self] in self?.history.setSampleInterval(seconds) }
        }
    }

    static func normalizedUpdateInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 1.0 }
        return min(max(seconds, 0.5), 60.0)
    }

    /// Caller must hold `lock`.
    private func startTimerLocked() {
        // Prime the delta baselines first, then fire quickly: rate metrics need two
        // samples, so without this the popover would read 0 for a whole interval
        // (up to 30s) every time polling resumes.
        queue.async { [weak self] in
            self?.sampler.primeBaselines()
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + min(updateInterval, 0.5),
                        repeating: .milliseconds(Int(updateInterval * 1000)),
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    // MARK: - Sampling

    /// Takes one sample synchronously, bypassing the timer. For tests.
    func sampleNow() {
        queue.sync { tick() }
    }

    /// Returns once all work queued on the sampler so far has run. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// Runs on `queue`. Samples everything off the main thread, then publishes once.
    private func tick() {
        let reading = sampler.read()
        latest.apply(reading)
        publish(latest, historySample: CoreMetricSample(reading: reading, date: clock()))
    }

    /// Runs on `queue`. Coalesces deliveries: at most one main-thread hop is queued
    /// at a time, and it carries the newest snapshot plus every history sample since
    /// the last hop. History is appended on every delivery, even when the snapshot is
    /// unchanged (a flat line is still data).
    private func publish(_ snapshot: StatsSnapshot, historySample: CoreMetricSample?) {
        lock.lock()
        let deliveryQueued = pendingSnapshot != nil
        pendingSnapshot = snapshot
        if let historySample {
            if pendingHistory.count >= Self.maxPendingHistory { pendingHistory.removeFirst() }
            pendingHistory.append(historySample)
        }
        lock.unlock()
        guard !deliveryQueued else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let next = self.pendingSnapshot
            self.pendingSnapshot = nil
            let samples = self.pendingHistory
            self.pendingHistory = []
            self.lock.unlock()
            self.history.record(samples)
            if let next, next != self.snapshot {
                self.snapshot = next
            }
        }
    }
}
