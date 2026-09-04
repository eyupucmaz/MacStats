import Darwin
import Foundation

struct NetworkSample {
    let downBytesPerSecond: Double
    let upBytesPerSecond: Double
}

/// Network throughput from getifaddrs(): if_data.ifi_ibytes / ifi_obytes summed over every
/// up, non-loopback AF_LINK interface, differentiated over a monotonic clock. Limitation:
/// ifi_*bytes are 32-bit on macOS and wrap at 4 GiB, so a decreasing total is reported as
/// zero traffic for that tick rather than a bogus spike.
final class NetworkMetrics {

    private var previousIn: UInt64?
    private var previousOut: UInt64?
    private var previousTime: UInt64 = 0

    /// Returns nil on the first call, when no elapsed time has passed, or on failure.
    func sample() -> NetworkSample? {
        guard let totals = readTotals() else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds

        defer {
            previousIn = totals.input
            previousOut = totals.output
            previousTime = now
        }
        guard let lastIn = previousIn, let lastOut = previousOut, now > previousTime else { return nil }

        let elapsed = Double(now - previousTime) / 1_000_000_000
        guard elapsed > 0 else { return nil }
        let inDelta = totals.input >= lastIn ? totals.input - lastIn : 0
        let outDelta = totals.output >= lastOut ? totals.output - lastOut : 0
        return NetworkSample(downBytesPerSecond: Double(inDelta) / elapsed,
                             upBytesPerSecond: Double(outDelta) / elapsed)
    }

    func reset() {
        previousIn = nil
        previousOut = nil
        previousTime = 0
    }

    private func readTotals() -> (input: UInt64, output: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var input: UInt64 = 0
        var output: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next

            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }

            input &+= UInt64(data.pointee.ifi_ibytes)
            output &+= UInt64(data.pointee.ifi_obytes)
        }
        return (input, output)
    }
}
