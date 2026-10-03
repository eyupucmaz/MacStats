import Foundation

/// Feeds the GPU detail page while it is visible: `start` in `onAppear`, `stop` in
/// `onDisappear`. Reads every accelerator on a utility queue and delivers a report on
/// the main queue right away, then every interval. The Metal device list is read once
/// per visit (it only changes when an eGPU is plugged in).
///
/// Cost, measured by `GPUDetailLiveTests.testLiveReportAndSampleCost` on an Apple M5:
/// about 0.04 ms of CPU per sample in a debug build, i.e. about 0.004 % of one core at a
/// 1 s interval. The first visit also loads Metal (see `GPUMetalDevice.readAll`).
final class GPUDetailSampler {

    private let readEntries: () -> [GPURegistryEntry]
    private let readMetal: () -> [GPUMetalDevice]

    /// `.workItem` drains the autoreleased IOKit and Metal objects after every read.
    private let queue = DispatchQueue(label: "com.macstats.GPUDetailSampler",
                                      qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a report taken just before `stop` is never delivered.
    private var generation = 0
    /// Only touched on `queue`; nil until the first read of a visit.
    private var metal: [GPUMetalDevice]?

    init(readEntries: @escaping () -> [GPURegistryEntry] = GPURegistry.readEntries,
         readMetal: @escaping () -> [GPUMetalDevice] = GPUMetalDevice.readAll) {
        self.readEntries = readEntries
        self.readMetal = readMetal
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
    func start(interval: TimeInterval = 1, onUpdate: @escaping (GPUDetailReport) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = Self.period(interval)

        let deliver: (GPUDetailReport) -> Void = { [weak self] report in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(report)
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
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

    /// Stops sampling; the next visit reads the Metal devices again.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        generation += 1
        lock.unlock()
        queue.async { [weak self] in self?.metal = nil }
    }

    /// One report taken synchronously on the sampler queue. For tests and cost measurement.
    func sampleNow() -> GPUDetailReport {
        queue.sync { read() }
    }

    static func period(_ interval: TimeInterval) -> TimeInterval {
        interval.isFinite ? min(max(interval, 0.5), 60) : 1
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    /// Runs on `queue`.
    private func read() -> GPUDetailReport {
        let metal = self.metal ?? readMetal()
        self.metal = metal
        return GPUDetailReport.make(entries: readEntries(), metal: metal)
    }
}
