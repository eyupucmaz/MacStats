import Foundation

/// The live part of the CPU page that is not in history: per-core load, load average
/// and thermal state.
struct CPUDetailReading: Equatable {
    /// Per-core load in `host_processor_info` order; nil until there is a baseline.
    var cores: [CPUSample?]?
    var loadAverage: CPULoadAverage?
    var thermalState: ProcessInfo.ThermalState
}

/// Where `CPUDetailSampler` gets its readings, injectable for tests.
protocol CPUDetailSource: AnyObject {
    /// Per-core load since the previous call; nil for the first call (no baseline).
    func sampleCores() -> [CPUSample?]?
    func resetCores()
    func loadAverage() -> CPULoadAverage?
    func thermalState() -> ProcessInfo.ThermalState
}

final class LiveCPUDetailSource: CPUDetailSource {
    /// Its own instance, so the engine's baseline is never disturbed.
    private let metrics = CPUMetrics()

    func sampleCores() -> [CPUSample?]? { metrics.sampleCores() }
    func resetCores() { metrics.reset() }
    func loadAverage() -> CPULoadAverage? { CPULoadAverage.read() }
    func thermalState() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

/// Feeds the CPU detail page while it is visible: `start` in `onAppear`, `stop` in
/// `onDisappear`. Samples on a utility queue and delivers on the main queue — once
/// right away (load average, thermal state) and then every interval with per-core load.
///
/// Cost, measured by `CPUDetailLiveTests.testSampleCost` on an Apple M5 (10 cores):
/// about 0.05 ms of CPU per sample in a debug build, i.e. about 0.005 % of one
/// core at a 1 s interval.
final class CPUDetailSampler {

    private let source: CPUDetailSource
    private let queue = DispatchQueue(label: "com.macstats.CPUDetailSampler", qos: .utility)
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a reading taken just before `stop` is never delivered.
    private var generation = 0

    init(source: CPUDetailSource = LiveCPUDetailSource()) {
        self.source = source
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
    func start(interval: TimeInterval = 1, onUpdate: @escaping (CPUDetailReading) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : 1

        let deliver: (CPUDetailReading) -> Void = { [weak self] reading in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(reading)
            }
        }
        // Baseline now, and show what needs none (load average, thermal state) at once.
        queue.async { [weak self] in
            guard let self else { return }
            self.source.resetCores()
            deliver(self.read())
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + period,
                        repeating: .milliseconds(Int(period * 1000)),
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            deliver(self.read())
        }
        timer = source
        source.resume()
    }

    /// Stops sampling and drops the per-core baseline, so a later `start` does not
    /// report the whole gap as one interval.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        generation += 1
        lock.unlock()
        queue.async { [weak self] in self?.source.resetCores() }
    }

    /// One reading taken synchronously on the sampler queue. For tests and cost measurement.
    func sampleNow() -> CPUDetailReading {
        queue.sync { read() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    /// Runs on `queue`.
    private func read() -> CPUDetailReading {
        CPUDetailReading(cores: source.sampleCores(),
                         loadAverage: source.loadAverage(),
                         thermalState: source.thermalState())
    }
}
