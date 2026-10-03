import Darwin
import IOKit.ps
import XCTest
@testable import MacStats

/// `BatteryDetailSampler` with an injected reader, the page model's history recording,
/// and one lenient live run that also prints the sampler's cost.
final class BatteryDetailSamplerTests: XCTestCase {

    private static let raw = BatteryDetailRaw(
        powerSource: [kIOPSCurrentCapacityKey: 55, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: true,
                      kIOPSPowerSourceStateKey: kIOPSACPowerValue],
        providingSource: kIOPSACPowerValue,
        registry: [SmartBatteryKey.voltage: 12_000, SmartBatteryKey.amperage: 2_000])

    func testStartDeliversRightAwayOnMainAndStopEndsIt() {
        let sampler = BatteryDetailSampler(read: { Self.raw })
        let delivered = expectation(description: "first reading")
        sampler.start(interval: 60) { detail in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(detail.battery?.level, 55)
            XCTAssertEqual(detail.battery?.watts, 24)
            delivered.fulfill()
        }
        XCTAssertTrue(sampler.isRunning)
        wait(for: [delivered], timeout: 2)
        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
    }

    func testNothingIsDeliveredAfterStop() {
        let sampler = BatteryDetailSampler(read: { Self.raw })
        let late = expectation(description: "no reading after stop")
        late.isInverted = true
        sampler.start(interval: 60) { _ in late.fulfill() }
        sampler.stop()
        wait(for: [late], timeout: 0.3)
    }

    func testModelRecordsPowerAndStateIntoHistory() throws {
        let history = MetricHistory()
        var battery = BatteryDetail.Battery(level: 55, state: .charging)
        battery.watts = 24
        BatteryDetailModel.record(battery, into: history)
        battery.state = .full
        battery.watts = nil
        BatteryDetailModel.record(battery, into: history)

        let watts = try XCTUnwrap(history.series(BatteryDetailSeries.watts, range: .oneMinute))
        XCTAssertEqual(watts.unit, .watts)
        XCTAssertEqual(watts.points.compactMap(\.value), [24], "a missing reading is not recorded as 0")
        let states = try XCTUnwrap(history.series(BatteryDetailSeries.state, range: .oneMinute))
        XCTAssertEqual(states.points.compactMap(\.value), [2, 1])
    }

    func testModelRecordsNothingWithoutReadings() {
        let history = MetricHistory()
        BatteryDetailModel.record(BatteryDetail.Battery(level: 55, state: nil), into: history)
        XCTAssertFalse(history.contains(BatteryDetailSeries.watts))
        XCTAssertFalse(history.contains(BatteryDetailSeries.state))
    }

    // MARK: - Live

    func testLiveSampleAndCost() {
        let sampler = BatteryDetailSampler()
        let detail = sampler.sampleNow()
        if let battery = detail.battery {
            XCTAssertTrue((0...100).contains(battery.level))
            if let health = battery.health { XCTAssertTrue((1...100).contains(health)) }
            if let watts = battery.watts { XCTAssertLessThan(abs(watts), 300) }
            if let minutes = battery.timeRemaining?.minutes { XCTAssertGreaterThan(minutes, 0) }
        }
        print("BatteryDetailSampler reading: \(detail)")

        let runs = 50
        let start = Self.processCPUNanoseconds()
        for _ in 0..<runs { _ = sampler.sampleNow() }
        let perSample = Double(Self.processCPUNanoseconds() - start) / Double(runs) / 1_000_000
        print(String(format: "BatteryDetailSampler cost: %.3f ms CPU per sample = %.4f %% of one core at 2 s",
                     perSample, perSample / 2_000 * 100))
        XCTAssertLessThan(perSample, 50, "a sample should be far cheaper than its interval")
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func nanoseconds(_ time: timeval) -> UInt64 { UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000 }
        return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
    }
}
