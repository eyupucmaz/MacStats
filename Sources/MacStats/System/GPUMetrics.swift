import Foundation
import IOKit

/// GPU utilization from the IOAccelerator IORegistry node's "PerformanceStatistics"
/// dictionary. Class matching includes subclasses, so this also finds Apple Silicon's
/// AGXAccelerator. Limitation: the keys are private and vary
/// by driver; when none of them is present there is no public alternative, so the caller
/// gets nil rather than a synthesized number.
enum GPUMetrics {

    private static let percentKeys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]
    private static let rawKeys = ["GPU Core Utilization"]

    /// Highest utilization across accelerators, or nil when nothing is readable.
    static func sample() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let raw = IORegistryEntryCreateCFProperty(service,
                                                            "PerformanceStatistics" as CFString,
                                                            kCFAllocatorDefault,
                                                            0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any] else { continue }

            var value: Double?
            for key in percentKeys {
                if let number = stats[key] as? NSNumber { value = number.doubleValue; break }
            }
            if value == nil {
                for key in rawKeys {
                    // Legacy drivers report busy time out of 10_000_000 rather than a percentage.
                    if let number = stats[key] as? NSNumber {
                        let v = number.doubleValue
                        value = v > 100 ? v / 100_000 : v
                        break
                    }
                }
            }
            if let value {
                let clamped = min(max(value, 0), 100)
                if clamped > (best ?? -1) { best = clamped }
            }
        }
        return best
    }
}
