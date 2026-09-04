import Combine
import Foundation

final class StatsEngine: ObservableObject {
    static let shared = StatsEngine()

    @Published var cpuUsage: Double = 0.0
    @Published var cpuUserUsage: Double = 0.0
    @Published var cpuSystemUsage: Double = 0.0
    @Published var memoryUsed: UInt64 = 0
    @Published var memoryTotal: UInt64 = 0
    @Published var memoryPressure: Double = 0.0
    @Published var gpuUsage: Double = 0.0
    @Published var diskReadBytes: Double = 0.0
    @Published var diskWriteBytes: Double = 0.0
    @Published var networkUpBytes: Double = 0.0
    @Published var networkDownBytes: Double = 0.0
    @Published var batteryLevel: Int = 0
    @Published var batteryState: String = "Unknown"
    @Published var batteryIsCharging: Bool = false
    @Published var batteryHealth: Int = 0
    @Published var batteryCycleCount: Int = 0
    @Published var fanRPM: Int = 0
    @Published var isFanAvailable: Bool = false
    @Published var temperature: Double = 0.0
    @Published var isTemperatureAvailable: Bool = false

    /// Bumped once at the end of every publish batch. Observers that need to
    /// react per sample subscribe here; `objectWillChange` fires once per
    /// property, i.e. ~20 times a tick.
    @Published private(set) var lastSampleAt: Date = .distantPast

    /// Number of logical cores seen by the last CPU sample.
    private(set) var coreCount: Int = 0

    private let queue = DispatchQueue(label: "com.macstats.StatsEngine.sampler", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var updateInterval: Double = 1.0

    private let cpu = CPUMetrics()
    private let disk = DiskMetrics()
    private let network = NetworkMetrics()
    private let battery = BatteryMetrics()

    init() {
        // No sampling until start(); the timer is owned solely by start()/stop().
        let memory = MemoryMetrics.sample()
        memoryTotal = memory.total
        memoryUsed = memory.used
        memoryPressure = memory.pressure
    }

    // MARK: - Lifecycle

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
            self.cpu.reset()
            self.disk.reset()
            self.network.reset()
            DispatchQueue.main.async {
                self.cpuUsage = 0
                self.cpuUserUsage = 0
                self.cpuSystemUsage = 0
                self.gpuUsage = 0
                self.diskReadBytes = 0
                self.diskWriteBytes = 0
                self.networkUpBytes = 0
                self.networkDownBytes = 0
            }
        }
    }

    /// Restarts the timer with a new period, clamped to 0.5...60 seconds.
    func setUpdateInterval(_ seconds: Double) {
        let clamped = Self.normalizedUpdateInterval(seconds)
        lock.lock()
        defer { lock.unlock() }
        updateInterval = clamped
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        startTimerLocked()
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
            guard let self else { return }
            _ = self.cpu.sample()
            _ = self.disk.sample()
            _ = self.network.sample()
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

    /// Runs on `queue`. Samples everything off the main thread, then publishes once.
    private func tick() {
        let cpuSample = cpu.sample()
        let memorySample = MemoryMetrics.sample()
        let gpuSample = GPUMetrics.sample()
        let diskSample = disk.sample()
        let networkSample = network.sample()
        let batterySample = battery.sample()
        let rpm = SMCService.shared.readFanRPM()
        let celsius = SMCService.shared.readCPUTemperature()
        let cores = cpu.coreCount

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coreCount = cores

            // First sample after start()/setUpdateInterval has no baseline: leave deltas at 0.
            if let cpuSample {
                self.cpuUsage = cpuSample.total
                self.cpuUserUsage = cpuSample.user
                self.cpuSystemUsage = cpuSample.system
            }
            self.memoryUsed = memorySample.used
            self.memoryTotal = memorySample.total
            self.memoryPressure = memorySample.pressure
            self.gpuUsage = gpuSample ?? 0
            if let diskSample {
                self.diskReadBytes = diskSample.readBytesPerSecond
                self.diskWriteBytes = diskSample.writeBytesPerSecond
            }
            if let networkSample {
                self.networkDownBytes = networkSample.downBytesPerSecond
                self.networkUpBytes = networkSample.upBytesPerSecond
            }
            self.batteryLevel = batterySample.level
            self.batteryState = batterySample.state
            self.batteryIsCharging = batterySample.isCharging
            self.batteryHealth = batterySample.health
            self.batteryCycleCount = batterySample.cycleCount
            self.fanRPM = rpm ?? 0
            self.isFanAvailable = rpm != nil
            self.temperature = celsius ?? 0
            self.isTemperatureAvailable = celsius != nil
            self.lastSampleAt = Date()
        }
    }
}
