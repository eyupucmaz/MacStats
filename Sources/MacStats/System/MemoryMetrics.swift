import Darwin
import Foundation

struct MemorySample {
    let used: UInt64      // bytes
    let total: UInt64     // bytes
    let pressure: Double  // 0...100
}

/// Memory from host_statistics64(HOST_VM_INFO64). Used = (active + wired + compressor)
/// pages, which tracks Activity Monitor's "Memory Used". Pressure is reported as
/// (wired + compressed) / total, the two components the kernel cannot evict on demand,
/// which is what Activity Monitor's pressure graph rises with. Limitation: not the
/// kernel's own pressure metric, so it is an approximation, not the exact same curve.
/// The detail page names the level with the kernel's own reading instead
/// (`MemoryPressureLevel`, from `kern.memorystatus_vm_pressure_level`).
enum MemoryMetrics {

    /// Each mach_host_self() call adds a send-right reference that is never released,
    /// so the port is fetched once rather than on every tick.
    private static let host = mach_host_self()

    /// The kernel's page size (16 KB on Apple silicon, 4 KB on Intel); every
    /// `vm_statistics64` count is in these pages.
    static var pageSize: UInt64 { UInt64(vm_kernel_page_size) }

    static func sample() -> MemorySample {
        let total = ProcessInfo.processInfo.physicalMemory
        guard let stats = vmStatistics() else {
            return MemorySample(used: 0, total: total, pressure: 0)
        }

        return derive(activePages: UInt64(stats.active_count),
                      wiredPages: UInt64(stats.wire_count),
                      compressorPages: UInt64(stats.compressor_page_count),
                      pageSize: pageSize,
                      total: total)
    }

    /// One `host_statistics64(HOST_VM_INFO64)` read; nil when the call fails.
    /// Shared with the memory detail page's sampler.
    static func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Used and pressure from page counts; both are capped at `total`.
    static func derive(activePages: UInt64, wiredPages: UInt64, compressorPages: UInt64,
                       pageSize: UInt64, total: UInt64) -> MemorySample {
        let active = activePages * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressorPages * pageSize

        let used = min(active + wired + compressed, total)
        let pressure = total > 0 ? min(100, Double(wired + compressed) / Double(total) * 100) : 0
        return MemorySample(used: used, total: total, pressure: pressure)
    }
}
