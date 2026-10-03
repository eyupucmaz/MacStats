import Darwin
import Foundation

/// Top processes by CPU, memory and disk I/O, for the detail pages. Unlike `StatsEngine`
/// it is not always on: a page calls `start` when it appears and `stop` when it goes
/// away. Sampling runs on a utility queue; reports are delivered on the main queue, the
/// first one after one interval (rates need two snapshots).
///
/// Cost, measured by `ProcessSamplerLiveTests.testSampleCost` on an Apple M5 (10 cores,
/// ~1,150 processes, ~880 readable): a steady-state sample (identities cached) takes
/// 1.6 ms of CPU in a release build (3.7 ms in debug), i.e. 0.08 % of one core at the
/// default 2 s interval. The baseline sample taken by `start` also resolves every
/// executable path and app, about 15 ms once.
final class ProcessSampler {

    private let reader: ProcessReading
    private let now: () -> UInt64

    /// `.workItem` drains the autoreleased AppKit objects (`NSRunningApplication`) after every tick.
    private let queue = DispatchQueue(label: "com.macstats.ProcessSampler",
                                      qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a report produced just before `stop` is never delivered.
    private var generation = 0

    // Only touched on `queue`.
    private var previous: (snapshot: ProcessSnapshot, time: UInt64)?
    private var identities: [pid_t: (startTime: UInt64, identity: ProcessIdentity)] = [:]

    /// `reader` and `now` (nanoseconds, monotonic) are injectable for tests.
    init(reader: ProcessReading = LibprocProcessReader(),
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.reader = reader
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
    func start(interval: TimeInterval = 2, onUpdate: @escaping (ProcessReport) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : 2

        // Baseline now, so the first report covers exactly one interval.
        queue.async { [weak self] in self?.prime() }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + period,
                        repeating: .milliseconds(Int(period * 1000)),
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self, let report = self.tick() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(report)
            }
        }
        timer = source
        source.resume()
    }

    /// Stops sampling and drops the baseline and identity cache, so a later `start` neither
    /// reports the idle gap as one interval nor keeps icons alive while no page is visible.
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        generation += 1
        lock.unlock()

        queue.async { [weak self] in
            self?.previous = nil
            self?.identities = [:]
        }
    }

    /// Takes one sample synchronously, bypassing the timer. Nil until there is a baseline.
    /// For tests and cost measurement.
    func sampleNow() -> ProcessReport? {
        queue.sync { tick() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    // MARK: - Sampling (on `queue`)

    private func prime() {
        let time = now()
        previous = (capture(), time)
    }

    private func tick() -> ProcessReport? {
        let time = now()
        let snapshot = capture()
        defer { previous = (snapshot, time) }
        guard let last = previous, time > last.time else { return nil }
        let elapsed = Double(time - last.time) / 1_000_000_000
        return ProcessReport.make(previous: last.snapshot, current: snapshot, elapsed: elapsed)
    }

    /// Reads every listed process. Identities are reused while PID and start time match,
    /// so paths and LaunchServices are only queried for processes new since the last tick.
    func capture() -> ProcessSnapshot {
        let pids = reader.allPIDs()
        let timebase = reader.timebase
        var entries: [pid_t: ProcessEntry] = Dictionary(minimumCapacity: pids.count)
        var seen: [pid_t: (startTime: UInt64, identity: ProcessIdentity)] = Dictionary(minimumCapacity: pids.count)
        var skipped = 0

        for pid in pids where entries[pid] == nil {
            switch reader.rusage(of: pid) {
            case .exited:
                continue
            case .denied:
                skipped += 1
            case .success(let usage):
                let identity: ProcessIdentity
                if let cached = identities[pid], cached.startTime == usage.startTime {
                    identity = cached.identity
                } else {
                    identity = resolveIdentity(of: pid)
                }
                seen[pid] = (usage.startTime, identity)
                entries[pid] = ProcessEntry(pid: pid,
                                            startTime: usage.startTime,
                                            cpuNanoseconds: timebase.nanoseconds(fromTicks: usage.cpuTicks),
                                            footprintBytes: usage.footprintBytes,
                                            diskReadBytes: usage.diskReadBytes,
                                            diskWrittenBytes: usage.diskWrittenBytes,
                                            identity: identity)
            }
        }
        identities = seen
        return ProcessSnapshot(entries: entries, skippedCount: skipped, coreCount: reader.coreCount)
    }

    private func resolveIdentity(of pid: pid_t) -> ProcessIdentity {
        let reader = self.reader
        return ProcessIdentity.make(path: reader.executablePath(of: pid),
                                    fallbackName: reader.shortName(of: pid) ?? String(pid),
                                    lookupApp: { reader.runningApp(pid: pid) })
    }
}
