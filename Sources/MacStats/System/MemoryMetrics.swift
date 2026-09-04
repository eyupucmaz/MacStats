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
enum MemoryMetrics {

    static func sample() -> MemorySample {
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemorySample(used: 0, total: total, pressure: 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let used = min(active + wired + compressed, total)
        let pressure = total > 0 ? min(100, Double(wired + compressed) / Double(total) * 100) : 0
        return MemorySample(used: used, total: total, pressure: pressure)
    }
}
