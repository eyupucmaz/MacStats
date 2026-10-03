import Foundation
import IOKit
import IOKit.ps

/// Reads the raw battery and power-adapter state: the IOPS power-source description,
/// time-remaining estimate and adapter details, plus the AppleSmartBattery properties
/// in `SmartBatteryKey`, fetched one by one so the gauge's large data blobs are never copied.
enum BatteryDetailReader {
    static func read() -> BatteryDetailRaw {
        var raw = BatteryDetailRaw()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            raw.providingSource = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
            // The same source the card reads: the first one with a capacity.
            raw.powerSource = sources.lazy
                .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
                .first { BatteryMetrics.reading(from: $0) != nil }
        }
        raw.timeRemainingEstimate = IOPSGetTimeRemainingEstimate()
        raw.adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        raw.registry = readRegistry()
        return raw
    }

    private static func readRegistry() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: [String: Any] = [:]
        for key in SmartBatteryKey.all {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() {
                properties[key] = value
            }
        }
        return properties
    }
}

/// Feeds the Battery page while it is visible: `start` in `onAppear`, `stop` in
/// `onDisappear`. Reads on a utility queue and delivers on main — once right away, then
/// every interval. The engine's own battery reading is untouched.
///
/// Cost, measured by `BatteryDetailLiveTests.testLiveSampleAndCost` on an Apple M5
/// MacBook: about 0.25 ms of CPU per sample, i.e. about 0.01 % of one core at 2 s.
final class BatteryDetailSampler {
    /// AppleSmartBattery refreshes its readings every few seconds; faster adds nothing.
    static let defaultInterval: TimeInterval = 2

    private let read: () -> BatteryDetailRaw
    private let queue = DispatchQueue(label: "com.macstats.BatteryDetailSampler",
                                      qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Guards `timer` and `generation`.
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Bumped by every start/stop so a reading taken just before `stop` is never delivered.
    private var generation = 0

    init(read: @escaping () -> BatteryDetailRaw = BatteryDetailReader.read) {
        self.read = read
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
    func start(interval: TimeInterval = defaultInterval, onUpdate: @escaping (BatteryDetail) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let period = interval.isFinite ? min(max(interval, 0.5), 60) : Self.defaultInterval

        let deliver: (BatteryDetail) -> Void = { [weak self] detail in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                onUpdate(detail)
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            deliver(self.sample())
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + period,
                        repeating: .milliseconds(Int(period * 1000)),
                        leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            deliver(self.sample())
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
    func sampleNow() -> BatteryDetail {
        queue.sync { sample() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil && generation == token
    }

    /// Runs on `queue`.
    private func sample() -> BatteryDetail {
        BatteryDetail.make(read())
    }
}
