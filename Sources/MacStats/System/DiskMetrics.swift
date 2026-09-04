import Foundation
import IOKit

struct DiskSample {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

/// Disk throughput from the "Statistics" dictionary of every IOBlockStorageDriver
/// ("Bytes (Read)" / "Bytes (Write)"), summed and differentiated over a monotonic clock.
/// Limitation: counters are cumulative since boot and drivers can come and go (external
/// disks), so a shrinking total is reported as no traffic instead of a negative rate.
final class DiskMetrics {

    private var previousRead: UInt64?
    private var previousWrite: UInt64?
    private var previousTime: UInt64 = 0

    /// Returns nil on the first call, when no elapsed time has passed, or on failure.
    func sample() -> DiskSample? {
        guard let totals = readTotals() else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds

        defer {
            previousRead = totals.read
            previousWrite = totals.write
            previousTime = now
        }
        guard let lastRead = previousRead, let lastWrite = previousWrite, now > previousTime else { return nil }

        let elapsed = Double(now - previousTime) / 1_000_000_000
        guard elapsed > 0 else { return nil }
        let readDelta = totals.read >= lastRead ? totals.read - lastRead : 0
        let writeDelta = totals.write >= lastWrite ? totals.write - lastWrite : 0
        return DiskSample(readBytesPerSecond: Double(readDelta) / elapsed,
                          writeBytesPerSecond: Double(writeDelta) / elapsed)
    }

    func reset() {
        previousRead = nil
        previousWrite = nil
        previousTime = 0
    }

    private func readTotals() -> (read: UInt64, write: UInt64)? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let raw = IORegistryEntryCreateCFProperty(service,
                                                            "Statistics" as CFString,
                                                            kCFAllocatorDefault,
                                                            0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any] else { continue }

            if let bytes = stats["Bytes (Read)"] as? NSNumber { read &+= bytes.uint64Value }
            if let bytes = stats["Bytes (Write)"] as? NSNumber { write &+= bytes.uint64Value }
        }
        return (read, write)
    }
}
