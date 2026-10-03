import Foundation

/// Feeds a detail page that reads more of the SMC than the engine does (Fan #31,
/// Temperature #32): `start` in `onAppear`, `stop` in `onDisappear`, nothing runs in
/// between. Calls `read` on a utility queue right away and then every interval, and
/// delivers each reading on the main queue. Read-only like `SMCService` itself.
///
/// Same lifecycle as `CPUDetailSampler`: a second `start` while running is a no-op, and
/// a reading taken just before `stop` is never delivered.
final class SMCDetailSampler<Reading> {

    private let read: () -> Reading
    private let queue: DispatchQueue
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a late reading from an earlier run is dropped.
    private var generation = 0

    init(label: String, read: @escaping () -> Reading) {
        self.read = read
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        timer?.cancel()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    /// `interval` is clamped to 0.5...60 s.
    func start(interval: TimeInterval, onUpdate: @escaping (Reading) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : 1

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(Int(period * 1000)),
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let reading = self.read()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(reading)
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        generation += 1
        lock.unlock()
    }

    /// One reading taken synchronously on the sampler queue. For tests and cost measurement.
    func sampleNow() -> Reading {
        queue.sync { read() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }
}
