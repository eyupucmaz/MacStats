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
    private let now: () -> UInt64
    private let readCapacity: (String) -> DiskSample?
    private var cached: DiskSample?
    private var cachedAt: UInt64 = 0

    /// `readCapacity` and `now` (nanoseconds, monotonic) are injectable for tests.
    init(volume: String = "/",
         refreshInterval: TimeInterval = 10,
         readCapacity: @escaping (String) -> DiskSample? = DiskMetrics.readCapacity(of:),
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.volume = volume
        self.refreshInterval = refreshInterval
        self.readCapacity = readCapacity
        self.now = now
    }

    /// Returns the last good reading when the volume cannot be queried, nil before the first one.
    func sample() -> DiskSample? {
        let time = now()
        if let cached, Double(time - cachedAt) / 1_000_000_000 < refreshInterval {
            return cached
        }
        guard let fresh = readCapacity(volume) else { return cached }
        cached = fresh
        cachedAt = time
        return fresh
    }

    static func readCapacity(of volume: String) -> DiskSample? {
        // A new URL each time: URL caches resource values per instance.
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return makeSample(total: Int64(total), available: available)
    }

    /// Free space is clamped to 0...total, so used never underflows. Nil for an empty volume.
    static func makeSample(total: Int64, available: Int64) -> DiskSample? {
        guard total > 0 else { return nil }
        let totalBytes = UInt64(total)
        let freeBytes = min(UInt64(max(available, 0)), totalBytes)
        return DiskSample(usedBytes: totalBytes - freeBytes, totalBytes: totalBytes)
    }
}
