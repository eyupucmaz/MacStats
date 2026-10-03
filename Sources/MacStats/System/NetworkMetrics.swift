import Darwin
import Foundation

struct NetworkSample {
    let downBytesPerSecond: Double
    let upBytesPerSecond: Double
}

/// Cumulative byte counters of one interface.
struct InterfaceCounters: Equatable {
    let name: String
    let inputBytes: UInt64
    let outputBytes: UInt64
}

/// Network throughput from sysctl(NET_RT_IFLIST2): the 64-bit if_data64 counters of each
/// interface, differenced per interface over a monotonic clock. getifaddrs()' if_data is
/// only 32 bits and wraps every 4 GiB, so it is not used.
///
/// Only physical links are counted — see `countsTraffic(of:)`. Tunnels, bridges and
/// peer-to-peer links carry traffic that also crosses a physical interface, so adding
/// them would double-count it (a VPN would show twice the real rate).
final class NetworkMetrics {

    private let readCounters: () -> [InterfaceCounters]?
    private let now: () -> UInt64
    private var previous: [String: InterfaceCounters]?
    private var previousTime: UInt64 = 0

    /// `readCounters` and `now` (nanoseconds, monotonic) are injectable for tests.
    init(readCounters: @escaping () -> [InterfaceCounters]? = NetworkMetrics.readInterfaceCounters,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.readCounters = readCounters
        self.now = now
    }

    /// The counting rule: Ethernet, Wi-Fi, USB/Thunderbolt adapters and tethering all
    /// appear as `en*`; cellular as `pdp_ip*`. Everything else — lo, utun/ipsec/ppp/tun/tap
    /// (VPNs), bridge, awdl/llw (AirDrop), ap (hotspot), anpi, gif/stf, vmenet (VMs) —
    /// is either local or a second view of traffic already counted on a physical link.
    static func countsTraffic(of interface: String) -> Bool {
        interface.hasPrefix("en") || interface.hasPrefix("pdp_ip")
    }

    /// Returns nil on the first call, when no time has elapsed, or on failure.
    func sample() -> NetworkSample? {
        guard let counters = readCounters() else { return nil }
        let time = now()
        let current = Dictionary(counters.filter { Self.countsTraffic(of: $0.name) }.map { ($0.name, $0) },
                                 uniquingKeysWith: { first, _ in first })

        defer {
            previous = current
            previousTime = time
        }
        guard let last = previous, time > previousTime else { return nil }

        let elapsed = Double(time - previousTime) / 1_000_000_000
        let delta = Self.delta(from: last, to: current)
        return NetworkSample(downBytesPerSecond: Double(delta.input) / elapsed,
                             upBytesPerSecond: Double(delta.output) / elapsed)
    }

    func reset() {
        previous = nil
        previousTime = 0
    }

    /// Bytes moved between two readings, summed over interfaces present in both. A counter
    /// that went backwards means the interface was re-created (e.g. an adapter replugged)
    /// and contributes nothing this tick, without zeroing the other interfaces.
    static func delta(from previous: [String: InterfaceCounters],
                      to current: [String: InterfaceCounters]) -> (input: UInt64, output: UInt64) {
        var input: UInt64 = 0
        var output: UInt64 = 0
        for (name, now) in current {
            guard let before = previous[name] else { continue }
            if now.inputBytes >= before.inputBytes { input &+= now.inputBytes - before.inputBytes }
            if now.outputBytes >= before.outputBytes { output &+= now.outputBytes - before.outputBytes }
        }
        return (input, output)
    }

    /// Every interface's counters, unfiltered.
    static func readInterfaceCounters() -> [InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Headroom in case an interface appears between the size query and the read.
        length += length / 8
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> [InterfaceCounters] in
            var result: [InterfaceCounters] = []
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr2>.size
            let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                // RTM_IFINFO2 is one per interface, followed by its link-level sockaddr_dl.
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      messageLength >= headerSize + MemoryLayout<sockaddr_dl>.size,
                      offset + messageLength <= length else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let link = raw.loadUnaligned(fromByteOffset: offset + headerSize, as: sockaddr_dl.self)
                let nameStart = offset + headerSize + nameOffset
                let nameEnd = nameStart + Int(link.sdl_nlen)
                guard nameEnd <= offset + messageLength else { continue }

                result.append(InterfaceCounters(name: String(decoding: raw[nameStart ..< nameEnd], as: UTF8.self),
                                                inputBytes: message.ifm_data.ifi_ibytes,
                                                outputBytes: message.ifm_data.ifi_obytes))
            }
            return result
        }
    }
}
