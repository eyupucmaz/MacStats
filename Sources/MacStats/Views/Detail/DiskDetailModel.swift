import AppKit
import Foundation

/// The live data behind the Disk page. Everything runs only between `start` (page
/// appears) and `stop` (page goes away): the disk activity sampler (1 s), the
/// process sampler (2 s) and a volume refresh every 10 s or when a volume mounts,
/// unmounts or is renamed (~20 ms of CPU per refresh, ~0.2 % of one core). Main
/// thread only; the readers run on utility queues.
final class DiskDetailModel: ObservableObject {
    /// The page's two history series (the store allows each page at most two).
    static let readSeries = "disk.read"
    static let writeSeries = "disk.write"
    static let activityInterval: TimeInterval = 1
    static let processInterval: TimeInterval = 2
    static let volumeInterval: TimeInterval = 10

    @Published private(set) var startup: DiskVolumeInfo?
    @Published private(set) var volumes: [DiskVolumeInfo] = []
    @Published private(set) var drive: DiskDriveInfo?
    /// Nil until the first reading.
    @Published private(set) var activity: DiskActivityReport?
    /// Set when the I/O counters cannot be read at all.
    @Published private(set) var isActivityUnavailable = false
    @Published private(set) var processes: ProcessReport?

    private let activitySampler: DiskActivitySampler
    private let processSampler: ProcessSampler
    private let queue = DispatchQueue(label: "com.macstats.DiskDetail.volumes", qos: .utility)
    private var volumeTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    /// Bumped by start/stop so a volume read finishing after `stop` is dropped.
    private var generation = 0
    private var hasLookedUpDrive = false
    private weak var history: MetricHistory?

    init(activitySampler: DiskActivitySampler = DiskActivitySampler(),
         processSampler: ProcessSampler = ProcessSampler()) {
        self.activitySampler = activitySampler
        self.processSampler = processSampler
    }

    deinit {
        volumeTimer?.cancel()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func start(history: MetricHistory) {
        guard volumeTimer == nil else { return }
        generation += 1
        self.history = history
        history.register(Self.readSeries, unit: .bytesPerSecond, interval: Self.activityInterval)
        history.register(Self.writeSeries, unit: .bytesPerSecond, interval: Self.activityInterval)

        activitySampler.start(interval: Self.activityInterval) { [weak self] report in
            self?.receive(report)
        }
        processSampler.start(interval: Self.processInterval) { [weak self] report in
            self?.processes = report
        }

        let token = generation
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(Int(Self.volumeInterval)), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refreshVolumes(token: token) }
        volumeTimer = timer
        timer.resume()

        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshVolumes(token: token)
            }
        }
    }

    func stop() {
        generation += 1
        activitySampler.stop()
        processSampler.stop()
        volumeTimer?.cancel()
        volumeTimer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        // A lookup cut short by `stop` is retried on the next visit.
        if drive == nil { hasLookedUpDrive = false }
    }

    private func receive(_ report: DiskActivityReport?) {
        guard let report else {
            isActivityUnavailable = activity == nil
            return
        }
        isActivityUnavailable = false
        activity = report
        if let rates = report.rates, let history {
            let now = Date()
            history.record(rates.readBytesPerSecond, for: Self.readSeries, unit: .bytesPerSecond, at: now)
            history.record(rates.writeBytesPerSecond, for: Self.writeSeries, unit: .bytesPerSecond, at: now)
        }
    }

    private func refreshVolumes(token: Int) {
        guard token == generation else { return }
        // The drive does not change while the Mac runs; one lookup per page visit.
        let lookUpDrive = !hasLookedUpDrive
        hasLookedUpDrive = true
        queue.async { [weak self] in
            let volumes = DiskVolumes.mountedVolumes()
            let startup = volumes.first(where: \.isStartup) ?? DiskVolumes.startupVolume()
            let drive = lookUpDrive ? startup?.bsdName.flatMap(DiskDriveInfo.read(bsdName:)) : nil
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.startup = startup
                self.volumes = volumes
                if lookUpDrive { self.drive = drive }
            }
        }
    }
}
