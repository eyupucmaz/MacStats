import Darwin
import Foundation

/// Reads a process's argv[0] from `KERN_PROCARGS2`, used to name processes whose
/// executable file name says nothing (e.g. Claude Code runs as ".../versions/2.1.288").
/// Same-user processes only, like the rest of the sampler; no root, no entitlements.
enum ProcessArguments {

    /// argv[0] of `pid`, or nil when the kernel refuses or the buffer is malformed.
    static func firstArgument(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return firstArgument(procargs: buffer.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: a native-endian `Int32` argc, the executable
    /// path, NUL padding, then argv[0], argv[1], … each NUL-terminated (then the
    /// environment). Nil when argc is 0 or argv[0] is missing or empty.
    static func firstArgument<Bytes: Collection>(procargs: Bytes) -> String? where Bytes.Element == UInt8 {
        let bytes = Array(procargs)
        let argcSize = MemoryLayout<Int32>.size
        guard bytes.count > argcSize else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = argcSize
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // padding
        let start = index
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // argv[0]
        // An unterminated argument means a truncated buffer, not a name.
        guard index > start, index < bytes.count else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}
