import Foundation

struct DiskSample {
    let usedBytes: UInt64
    let totalBytes: UInt64
}

/// Capacity of the startup volume. Free space is "available for important usage",
/// the figure Finder shows: it counts purgeable space (caches, local snapshots) as free.
/// The query costs a few milliseconds and capacity changes slowly, so a reading is
/// reused for `refreshInterval` instead of being taken on every tick.
final class DiskMetrics {

    private let volume: String
    private let refreshInterval: TimeInterval
    private var cached: DiskSample?
    private var cachedAt: UInt64 = 0

    init(volume: String = "/", refreshInterval: TimeInterval = 10) {
        self.volume = volume
        self.refreshInterval = refreshInterval
    }

    /// Returns nil when the volume cannot be queried.
    func sample() -> DiskSample? {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached, Double(now - cachedAt) / 1_000_000_000 < refreshInterval {
            return cached
        }
        guard let fresh = readCapacity() else { return cached }
        cached = fresh
        cachedAt = now
        return fresh
    }

    private func readCapacity() -> DiskSample? {
        // A new URL each time: URL caches resource values per instance.
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }

        let totalBytes = UInt64(total)
        let freeBytes = min(UInt64(max(available, 0)), totalBytes)
        return DiskSample(usedBytes: totalBytes - freeBytes, totalBytes: totalBytes)
    }
}
