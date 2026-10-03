import AppKit
import Darwin
import Foundation

/// The raw counters of one process, as `proc_pid_rusage(RUSAGE_INFO_V4)` returns them.
struct ProcessRusage: Equatable {
    let pid: pid_t
    /// `ri_proc_start_abstime`: distinguishes a reused PID from the process that had it before.
    let startTime: UInt64
    /// `ri_user_time + ri_system_time`, in mach absolute time units (not nanoseconds on Apple silicon).
    let cpuTicks: UInt64
    /// `ri_phys_footprint`: the figure Activity Monitor shows as "Memory".
    let footprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
}

enum ProcessRusageResult: Equatable {
    case success(ProcessRusage)
    /// The kernel refused (EPERM and friends): typically another user's or a protected process.
    case denied
    /// The process exited between being listed and being read.
    case exited
}

/// What LaunchServices knows about a process that is a running application.
struct ProcessAppInfo {
    let name: String?
    let icon: NSImage?
    /// `activationPolicy == .regular`: a Dock app, as opposed to a helper or agent.
    let isRegular: Bool
}

/// Mach absolute time → nanoseconds. 1/1 on Intel, 125/3 on Apple silicon.
struct ProcessTimebase: Equatable {
    let numer: UInt32
    let denom: UInt32

    static let current: ProcessTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            return ProcessTimebase(numer: 1, denom: 1)
        }
        return ProcessTimebase(numer: info.numer, denom: info.denom)
    }()

    /// Exact (full-width) conversion; saturates instead of trapping on overflow.
    func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        guard denom > 0 else { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        let divisor = UInt64(denom)
        guard product.high < divisor else { return .max }
        return divisor.dividingFullWidth(product).quotient
    }
}

/// Everything the sampler needs from the OS, injectable so the maths can be tested
/// with synthetic snapshots.
protocol ProcessReading {
    var timebase: ProcessTimebase { get }
    var coreCount: Int { get }
    func allPIDs() -> [pid_t]
    func rusage(of pid: pid_t) -> ProcessRusageResult
    func executablePath(of pid: pid_t) -> String?
    /// `proc_name`: the short (possibly truncated) process name.
    func shortName(of pid: pid_t) -> String?
    func runningApp(pid: pid_t) -> ProcessAppInfo?
    /// argv[0], for naming processes whose executable is called e.g. "2.1.288".
    func firstArgument(of pid: pid_t) -> String?
}

extension ProcessReading {
    func firstArgument(of pid: pid_t) -> String? { nil }
}

/// Public libproc + AppKit only: no private APIs, no root, no entitlements. Processes the
/// kernel will not let this user inspect come back as `.denied`.
struct LibprocProcessReader: ProcessReading {

    var timebase: ProcessTimebase { .current }

    var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    func allPIDs() -> [pid_t] {
        // With no buffer, the return value is the number of PIDs right now.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    func rusage(of pid: pid_t) -> ProcessRusageResult {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return errno == ESRCH ? .exited : .denied }
        return .success(ProcessRusage(pid: pid,
                                      startTime: info.ri_proc_start_abstime,
                                      cpuTicks: info.ri_user_time &+ info.ri_system_time,
                                      footprintBytes: info.ri_phys_footprint,
                                      diskReadBytes: info.ri_diskio_bytesread,
                                      diskWrittenBytes: info.ri_diskio_byteswritten))
    }

    func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    func shortName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    func runningApp(pid: pid_t) -> ProcessAppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return ProcessAppInfo(name: app.localizedName, icon: app.icon, isRegular: app.activationPolicy == .regular)
    }

    func firstArgument(of pid: pid_t) -> String? {
        ProcessArguments.firstArgument(of: pid)
    }
}
