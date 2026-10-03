import XCTest
@testable import MacStats

/// Interface list, addresses, path and Wi-Fi derivations of the Network page.
final class NetworkDetailReportTests: XCTestCase {

    private typealias Totals = NetworkTrafficLedger.Totals
    private typealias Raw = InterfaceAddresses.Raw

    private func counters(_ name: String, _ input: UInt64, _ output: UInt64, speed: UInt64 = 0) -> InterfaceCounters {
        InterfaceCounters(name: name, inputBytes: input, outputBytes: output, linkSpeed: speed)
    }

    private func path(_ interfaces: [(String, NetworkInterfaceKind)], satisfied: Bool = true) -> NetworkPathSummary {
        NetworkPathSummary(isSatisfied: satisfied,
                           interfaces: interfaces.map { NetworkPathSummary.Interface(name: $0.0, kind: $0.1) })
    }

    // MARK: Path

    func testPrimaryIsTheFirstCountedInterfaceOfASatisfiedPath() {
        XCTAssertEqual(path([("en0", .wifi), ("en7", .ethernet)]).primaryInterface, "en0")
        XCTAssertEqual(path([("utun4", .other), ("en7", .ethernet)]).primaryInterface, "en7",
                       "a VPN tunnel ahead of the physical link is not the primary interface")
        XCTAssertNil(path([("en0", .wifi)], satisfied: false).primaryInterface)
        XCTAssertNil(path([]).primaryInterface)
    }

    // MARK: Addresses

    func testAddressesGroupPerInterfaceWithoutDuplicates() {
        let addresses = InterfaceAddresses.make([
            Raw(interface: "en0", isIPv6: false, address: "192.168.1.20"),
            Raw(interface: "en0", isIPv6: true, address: "fe80::1c2b:3a%en0"),
            Raw(interface: "en0", isIPv6: true, address: "2a02:1:2::5"),
            Raw(interface: "en0", isIPv6: true, address: "2a02:1:2::5"),
            Raw(interface: "en7", isIPv6: false, address: "10.0.0.4"),
        ])
        XCTAssertEqual(addresses["en0"], InterfaceAddresses(ipv4: ["192.168.1.20"], ipv6: ["2a02:1:2::5"]))
        XCTAssertEqual(addresses["en7"], InterfaceAddresses(ipv4: ["10.0.0.4"], ipv6: []))
    }

    func testLinkLocalIPv6IsKeptOnlyWhenItIsTheOnlyOne() {
        let addresses = InterfaceAddresses.make([
            Raw(interface: "en5", isIPv6: true, address: "fe80::aede:48ff:fe00:1122%en5"),
        ])
        XCTAssertEqual(addresses["en5"]?.ipv6, ["fe80::aede:48ff:fe00:1122"])
    }

    func testLinkLocalDetectionCoversTheWholePrefix() {
        for address in ["fe80::1", "FE80::1", "fe9a::1", "feab::1", "febf::1"] {
            XCTAssertTrue(InterfaceAddresses.isLinkLocalIPv6(address), address)
        }
        for address in ["fec0::1", "fd00::1", "2001:db8::1", "::1", "fe8"] {
            XCTAssertFalse(InterfaceAddresses.isLinkLocalIPv6(address), address)
        }
        XCTAssertEqual(InterfaceAddresses.stripScope("fe80::1%utun2"), "fe80::1")
        XCTAssertEqual(InterfaceAddresses.stripScope("192.168.1.2"), "192.168.1.2")
    }

    // MARK: Wi-Fi

    func testWiFiNeedsPowerAChannelAndASignal() {
        let associated = WiFiDetails.Raw(interface: "en0", isPoweredOn: true, ssid: nil, rssi: -62, noise: -90,
                                         transmitRate: 866.7, channel: 36, band: 2)
        XCTAssertEqual(WiFiDetails.make(associated),
                       WiFiDetails(interface: "en0", networkName: nil, rssi: -62, noise: -90,
                                   transmitRate: 866.7, channel: 36, band: .ghz5))

        var off = associated
        off.isPoweredOn = false
        XCTAssertNil(WiFiDetails.make(off))
        var unassociated = associated
        unassociated.channel = nil
        unassociated.rssi = 0
        XCTAssertNil(WiFiDetails.make(unassociated))
        XCTAssertNil(WiFiDetails.make(WiFiDetails.Raw()))
    }

    func testWiFiHidesReadingsCoreWLANDoesNotHave() throws {
        let raw = WiFiDetails.Raw(interface: "en0", isPoweredOn: true, ssid: "  ", rssi: -70, noise: 0,
                                  transmitRate: 0, channel: 6, band: 0)
        let wifi = try XCTUnwrap(WiFiDetails.make(raw))
        XCTAssertNil(wifi.noise)
        XCTAssertNil(wifi.transmitRate)
        XCTAssertNil(wifi.band)
        XCTAssertNil(wifi.networkName, "a blank SSID is not a name")

        var named = raw
        named.ssid = "Home"
        named.band = 3
        XCTAssertEqual(WiFiDetails.make(named)?.networkName, "Home")
        XCTAssertEqual(WiFiDetails.make(named)?.band, .ghz6)
    }

    // MARK: Report

    func testReportListsInterfacesInUsePrimaryFirst() {
        let report = NetworkDetailReport.make(
            counters: [counters("en0", 5_000, 1_000), counters("en1", 0, 0), counters("en7", 9_000, 3_000, speed: 1_000_000_000),
                       counters("lo0", 77, 77), counters("utun3", 500, 500)],
            previous: nil, elapsed: nil,
            addresses: InterfaceAddresses.make([Raw(interface: "en7", isIPv6: false, address: "10.0.0.4"),
                                                Raw(interface: "lo0", isIPv6: false, address: "127.0.0.1")]),
            path: path([("utun3", .other), ("en0", .wifi)]),
            wifi: nil, session: nil)
        XCTAssertEqual(report.interfaces.map(\.name), ["en0", "en7"],
                       "idle ports, loopback and tunnels are not listed")
        XCTAssertTrue(report.interfaces[0].isPrimary)
        XCTAssertFalse(report.interfaces[1].isPrimary)
        XCTAssertEqual(report.interfaces[1].kind, .other, "not on the path and not the Wi-Fi interface")
        XCTAssertNil(report.interfaces[1].linkSpeed, "link speed is for Ethernet only")
        XCTAssertEqual(report.sinceBoot, Totals(inputBytes: 14_000, outputBytes: 4_000), "counted interfaces only")
        XCTAssertNil(report.sinceStart)
        XCTAssertNil(report.interfaces[0].downRate, "no rate without a baseline")
    }

    func testReportRatesTotalsAndLinkSpeed() throws {
        let report = NetworkDetailReport.make(
            counters: [counters("en0", 5_000, 1_000), counters("en7", 9_000, 3_000, speed: 2_500_000_000)],
            previous: ["en0": counters("en0", 1_000, 0), "en7": counters("en7", 10_000, 2_000)],
            elapsed: 2,
            addresses: [:],
            path: path([("en7", .ethernet), ("en0", .wifi)]),
            wifi: WiFiDetails.Raw(interface: "en0", isPoweredOn: true, rssi: -50, channel: 149, band: 2),
            session: ["en0": Totals(inputBytes: 700, outputBytes: 70), "en9": Totals(inputBytes: 300, outputBytes: 30)])
        let ethernet = try XCTUnwrap(report.interfaces.first { $0.name == "en7" })
        let wifi = try XCTUnwrap(report.interfaces.first { $0.name == "en0" })

        XCTAssertEqual(report.interfaces.map(\.name), ["en7", "en0"])
        XCTAssertEqual(ethernet.linkSpeed, 2_500_000_000)
        XCTAssertNil(ethernet.downRate, "a counter that went backwards gives no rate")
        XCTAssertEqual(wifi.downRate, 2_000)
        XCTAssertEqual(wifi.upRate, 500)
        XCTAssertEqual(wifi.sinceStart, Totals(inputBytes: 700, outputBytes: 70))
        XCTAssertEqual(ethernet.sinceStart, Totals(), "seen since launch but idle")
        XCTAssertEqual(report.sinceStart, Totals(inputBytes: 1_000, outputBytes: 100),
                       "an interface that went away still counts toward the session")
        XCTAssertEqual(report.wifi?.channel, 149)
    }

    func testWiFiInterfaceIsNamedEvenOffThePath() {
        let report = NetworkDetailReport.make(
            counters: [counters("en0", 1, 1)], previous: nil, elapsed: nil,
            addresses: InterfaceAddresses.make([Raw(interface: "en0", isIPv6: false, address: "169.254.3.4")]),
            path: NetworkPathSummary(), wifi: WiFiDetails.Raw(interface: "en0"), session: nil)
        XCTAssertEqual(report.interfaces.first?.kind, .wifi)
        XCTAssertNil(report.wifi, "not associated")
        XCTAssertFalse(report.interfaces[0].isPrimary, "no satisfied path, no primary")
    }

    func testUnreadableCountersHideTotalsRatherThanShowZero() {
        let report = NetworkDetailReport.make(counters: nil, previous: nil, elapsed: nil, addresses: [:],
                                              path: path([("en0", .wifi)]), wifi: nil, session: nil)
        XCTAssertNil(report.sinceBoot)
        XCTAssertEqual(report.interfaces.map(\.name), ["en0"])
        XCTAssertNil(report.interfaces[0].sinceBoot)
    }

    func testNoInterfacesWhenOffline() {
        let report = NetworkDetailReport.make(counters: [counters("en0", 1, 1)], previous: nil, elapsed: nil,
                                              addresses: [:], path: NetworkPathSummary(), wifi: nil, session: nil)
        XCTAssertTrue(report.interfaces.isEmpty)
    }

    // MARK: Sampler

    func testSamplerReportsRatesFromItsSecondReadingAndFeedsTheLedger() {
        var readings = [[counters("en0", 1_000, 1_000)], [counters("en0", 3_000, 2_000)]]
        var time: UInt64 = 0
        let ledger = NetworkTrafficLedger()
        let sampler = NetworkDetailSampler(
            readCounters: { readings.isEmpty ? nil : readings.removeFirst() },
            readAddresses: { [Raw(interface: "en0", isIPv6: false, address: "192.168.0.2")] },
            readWiFi: { nil },
            ledger: ledger,
            now: { time += 1_000_000_000; return time })

        let first = sampler.sampleNow()
        XCTAssertEqual(first.interfaces.map(\.name), ["en0"])
        XCTAssertNil(first.interfaces[0].downRate)
        XCTAssertEqual(first.interfaces[0].sinceStart, Totals(), "the page's reading is the baseline here")

        let second = sampler.sampleNow()
        XCTAssertEqual(second.interfaces[0].downRate, 2_000)
        XCTAssertEqual(second.interfaces[0].upRate, 1_000)
        XCTAssertEqual(second.sinceStart, Totals(inputBytes: 2_000, outputBytes: 1_000))
        XCTAssertEqual(second.sinceBoot, Totals(inputBytes: 3_000, outputBytes: 2_000))

        let failed = sampler.sampleNow()
        XCTAssertNil(failed.sinceBoot, "a failed read hides the counters")
        XCTAssertNil(failed.interfaces.first?.downRate)
    }
}
