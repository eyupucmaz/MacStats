import XCTest
@testable import MacStats

/// "Since MacStats started" totals, driven by injected counter readings.
final class NetworkDetailLedgerTests: XCTestCase {

    private func counters(_ name: String, _ input: UInt64, _ output: UInt64) -> InterfaceCounters {
        InterfaceCounters(name: name, inputBytes: input, outputBytes: output)
    }

    private typealias Totals = NetworkTrafficLedger.Totals

    func testFirstReadingIsTheBaseline() {
        let ledger = NetworkTrafficLedger()
        XCTAssertFalse(ledger.hasBaseline)
        ledger.record([counters("en0", 5_000_000, 1_000_000)])
        XCTAssertTrue(ledger.hasBaseline)
        XCTAssertEqual(ledger.perInterface(), [:], "bytes moved before launch are not ours")
    }

    func testGrowthAccumulatesAcrossReadingsAndGaps() {
        let ledger = NetworkTrafficLedger()
        ledger.record([counters("en0", 1_000, 500)])
        ledger.record([counters("en0", 1_600, 700)])
        // A long sampling pause is one large step of the same counters: nothing is lost.
        ledger.record([counters("en0", 9_600, 2_700)])
        XCTAssertEqual(ledger.perInterface()["en0"], Totals(inputBytes: 8_600, outputBytes: 2_200))
    }

    func testRecreatedInterfaceCountsFromZero() {
        let ledger = NetworkTrafficLedger()
        ledger.record([counters("en5", 10_000, 10_000)])
        ledger.record([counters("en5", 12_000, 11_000)])
        // Adapter replugged: counters restart, and everything on them is new.
        ledger.record([counters("en5", 300, 100)])
        ledger.record([counters("en5", 800, 150)])
        XCTAssertEqual(ledger.perInterface()["en5"], Totals(inputBytes: 2_800, outputBytes: 1_150))
    }

    func testInterfaceAppearingAfterLaunchCountsWholly() {
        let ledger = NetworkTrafficLedger()
        ledger.record([counters("en0", 100, 100)])
        ledger.record([counters("en0", 100, 100), counters("pdp_ip0", 4_000, 2_000)])
        XCTAssertEqual(ledger.perInterface()["pdp_ip0"], Totals(inputBytes: 4_000, outputBytes: 2_000))
        XCTAssertEqual(ledger.perInterface()["en0"], Totals())
    }

    func testInterfaceThatComesBackIsNotCountedTwice() {
        let ledger = NetworkTrafficLedger()
        ledger.record([counters("en0", 0, 0), counters("en7", 1_000, 1_000)])
        ledger.record([counters("en0", 0, 0)])
        ledger.record([counters("en0", 0, 0), counters("en7", 1_500, 1_000)])
        XCTAssertEqual(ledger.perInterface()["en7"], Totals(inputBytes: 500, outputBytes: 0))
    }

    func testUncountedInterfacesAreIgnored() {
        let ledger = NetworkTrafficLedger()
        ledger.record([counters("en0", 0, 0), counters("utun3", 0, 0), counters("lo0", 0, 0)])
        ledger.record([counters("en0", 10, 10), counters("utun3", 9_999, 9_999), counters("lo0", 9_999, 9_999)])
        XCTAssertEqual(Set(ledger.perInterface().keys), ["en0"])
    }

    func testEngineMetricsFeedTheLedger() {
        let ledger = NetworkTrafficLedger()
        var readings = [[counters("en0", 1_000, 1_000)], [counters("en0", 4_000, 2_000)]]
        let metrics = NetworkMetrics(readCounters: { readings.isEmpty ? nil : readings.removeFirst() },
                                     ledger: ledger)
        _ = metrics.sample()
        metrics.reset() // a sampling pause drops the rate baseline, never the session's
        _ = metrics.sample()
        XCTAssertEqual(ledger.perInterface()["en0"], Totals(inputBytes: 3_000, outputBytes: 1_000))
    }
}
