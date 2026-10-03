import CoreWLAN
import Darwin
import Foundation
import Network

// What the Network page shows about each link besides its counters: kind, local
// addresses and Wi-Fi radio details. Readers return raw values; the static `make`
// functions turn them into what is shown, and are what the tests drive.

/// How an interface connects, as the Network page names it.
enum NetworkInterfaceKind: Equatable {
    case wifi
    case ethernet
    case other
}

/// The parts of an `NWPath` the page uses. `NWPath`/`NWInterface` cannot be built in
/// tests, so the live monitor converts to this.
struct NetworkPathSummary: Equatable {
    struct Interface: Equatable {
        let name: String
        let kind: NetworkInterfaceKind
    }

    var isSatisfied = false
    /// In the system's order of preference, first is the default route.
    var interfaces: [Interface] = []

    /// The physical link carrying the default route: the most preferred *counted*
    /// interface. A VPN tunnel listed ahead of it only re-wraps traffic that leaves
    /// through this link, and the page lists counted interfaces only.
    var primaryInterface: String? {
        guard isSatisfied else { return nil }
        return interfaces.first { NetworkMetrics.countsTraffic(of: $0.name) }?.name
    }

    func kind(of name: String) -> NetworkInterfaceKind? {
        interfaces.first { $0.name == name }?.kind
    }

    init(isSatisfied: Bool = false, interfaces: [Interface] = []) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        interfaces = path.availableInterfaces.map { interface in
            let kind: NetworkInterfaceKind
            switch interface.type {
            case .wifi: kind = .wifi
            case .wiredEthernet: kind = .ethernet
            default: kind = .other
            }
            return Interface(name: interface.name, kind: kind)
        }
    }
}

// MARK: - Addresses

/// Local IP addresses of one interface, as shown.
struct InterfaceAddresses: Equatable {
    var ipv4: [String] = []
    var ipv6: [String] = []

    var isEmpty: Bool { ipv4.isEmpty && ipv6.isEmpty }

    /// One raw `getifaddrs` entry.
    struct Raw: Equatable {
        let interface: String
        let isIPv6: Bool
        let address: String
    }

    /// Groups raw entries by interface, in their original order, without duplicates.
    /// Link-local IPv6 (`fe80::/10`, the "%en0" scoped ones) is dropped when the
    /// interface has another IPv6 address: it is the same on every network and only
    /// worth showing when it is all there is.
    static func make(_ raw: [Raw]) -> [String: InterfaceAddresses] {
        var result: [String: InterfaceAddresses] = [:]
        var linkLocal: [String: [String]] = [:]
        for entry in raw {
            var addresses = result[entry.interface] ?? InterfaceAddresses()
            if entry.isIPv6 {
                let address = stripScope(entry.address)
                if isLinkLocalIPv6(address) {
                    if !(linkLocal[entry.interface] ?? []).contains(address) {
                        linkLocal[entry.interface, default: []].append(address)
                    }
                } else if !addresses.ipv6.contains(address) {
                    addresses.ipv6.append(address)
                }
            } else if !addresses.ipv4.contains(entry.address) {
                addresses.ipv4.append(entry.address)
            }
            result[entry.interface] = addresses
        }
        for (interface, local) in linkLocal where result[interface]?.ipv6.isEmpty == true {
            result[interface]?.ipv6 = local
        }
        return result
    }

    /// "fe80::1%en0" → "fe80::1".
    static func stripScope(_ address: String) -> String {
        address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
    }

    /// fe80::/10: the first 10 bits are 1111111010, so "fe8"…"feb".
    static func isLinkLocalIPv6(_ address: String) -> Bool {
        let head = address.lowercased().prefix(4)
        guard head.count == 4, head.hasPrefix("fe") else { return false }
        return ["8", "9", "a", "b"].contains(head.dropFirst(2).prefix(1))
    }

    /// Every IPv4/IPv6 address of every interface, numeric, from `getifaddrs`.
    static func readRaw() -> [Raw] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Raw] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size
                                                     : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            result.append(Raw(interface: String(cString: entry.pointee.ifa_name),
                              isIPv6: family == AF_INET6,
                              address: String(cString: host)))
        }
        return result
    }
}

// MARK: - Wi-Fi

/// The associated Wi-Fi link's radio details. Each value is nil when CoreWLAN does
/// not report it (CoreWLAN answers 0 for a reading it does not have).
struct WiFiDetails: Equatable {
    enum Band: Equatable {
        case ghz2_4
        case ghz5
        case ghz6
    }

    let interface: String
    /// Only when macOS hands it over without Location access, which MacStats never asks for.
    var networkName: String?
    /// dBm.
    var rssi: Int?
    /// dBm.
    var noise: Int?
    /// Mbit/s.
    var transmitRate: Double?
    var channel: Int?
    var band: Band?

    /// What CoreWLAN reported, unvalidated.
    struct Raw: Equatable {
        var interface: String?
        var isPoweredOn = false
        var ssid: String?
        var rssi = 0
        var noise = 0
        var transmitRate = 0.0
        /// Nil when not associated.
        var channel: Int?
        /// `CWChannelBand` raw value: 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz, 0 = unknown.
        var band = 0
    }

    /// Nil unless the radio is on and associated (it has a channel and a signal).
    static func make(_ raw: Raw) -> WiFiDetails? {
        guard let interface = raw.interface, raw.isPoweredOn,
              let channel = raw.channel, channel > 0, raw.rssi < 0 else { return nil }
        let band: Band?
        switch raw.band {
        case 1: band = .ghz2_4
        case 2: band = .ghz5
        case 3: band = .ghz6
        default: band = nil
        }
        let name = raw.ssid?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WiFiDetails(interface: interface,
                           networkName: name?.isEmpty == false ? name : nil,
                           rssi: raw.rssi,
                           noise: raw.noise < 0 ? raw.noise : nil,
                           transmitRate: raw.transmitRate > 0 && raw.transmitRate.isFinite ? raw.transmitRate : nil,
                           channel: channel,
                           band: band)
    }
}

/// Reads the default Wi-Fi interface through CoreWLAN. Never asks for Location access:
/// without it, macOS 14+ returns nil for the SSID and the page simply omits it.
final class WiFiReader {
    private var interface: CWInterface?

    init() {}

    /// The Wi-Fi interface's name even when it is not associated, so the page can name
    /// the en* interface "Wi-Fi" when the path monitor does not list it.
    func read() -> WiFiDetails.Raw? {
        if interface == nil { interface = CWWiFiClient.shared().interface() }
        guard let interface else { return nil }
        let channel = interface.wlanChannel()
        return WiFiDetails.Raw(interface: interface.interfaceName,
                               isPoweredOn: interface.powerOn(),
                               ssid: interface.ssid(),
                               rssi: interface.rssiValue(),
                               noise: interface.noiseMeasurement(),
                               transmitRate: interface.transmitRate(),
                               channel: channel?.channelNumber,
                               band: channel?.channelBand.rawValue ?? 0)
    }
}
