import IOKit.ps
import XCTest
@testable import MacStats

/// Power-source description parsing and health maths of `BatteryMetrics`.
/// Descriptions are built by hand, so no battery is needed.
final class BatteryMetricsTests: XCTestCase {

    private func description(current: Int? = 50, max: Int? = 100,
                             charging: Bool? = nil, charged: Bool? = nil,
                             powerState: String? = nil) -> [String: Any] {
        var d: [String: Any] = [:]
        d[kIOPSCurrentCapacityKey] = current
        d[kIOPSMaxCapacityKey] = max
        d[kIOPSIsChargingKey] = charging
        d[kIOPSIsChargedKey] = charged
        d[kIOPSPowerSourceStateKey] = powerState
        return d
    }

    // MARK: - State

    func testStatePrecedence() {
        // Charging wins over everything, then a full battery, then the power source.
        XCTAssertEqual(BatteryMetrics.state(isCharging: true, isCharged: true, powerState: kIOPSACPowerValue), "Charging")
        XCTAssertEqual(BatteryMetrics.state(isCharging: false, isCharged: true, powerState: kIOPSACPowerValue), "Full")
        XCTAssertEqual(BatteryMetrics.state(isCharging: false, isCharged: false, powerState: kIOPSACPowerValue), "AC Power")
        XCTAssertEqual(BatteryMetrics.state(isCharging: false, isCharged: false, powerState: kIOPSBatteryPowerValue), "Discharging")
        XCTAssertEqual(BatteryMetrics.state(isCharging: false, isCharged: false, powerState: kIOPSOffLineValue), "Unknown")
        XCTAssertEqual(BatteryMetrics.state(isCharging: false, isCharged: false, powerState: nil), "Unknown")
    }

    // MARK: - Description → reading

    func testLevelIsCurrentOverMaxRounded() {
        let reading = BatteryMetrics.reading(from: description(current: 2, max: 3, powerState: kIOPSBatteryPowerValue))
        XCTAssertEqual(reading?.level, 67)
        XCTAssertEqual(reading?.state, "Discharging")
        XCTAssertEqual(reading?.isCharging, false)
    }

    func testLevelIsClampedToAPercentage() {
        XCTAssertEqual(BatteryMetrics.reading(from: description(current: 120, max: 100))?.level, 100)
        XCTAssertEqual(BatteryMetrics.reading(from: description(current: -5, max: 100))?.level, 0)
    }

    func testChargingFlagsAreRead() {
        let charging = BatteryMetrics.reading(from: description(charging: true, powerState: kIOPSACPowerValue))
        XCTAssertEqual(charging?.state, "Charging")
        XCTAssertEqual(charging?.isCharging, true)

        let full = BatteryMetrics.reading(from: description(current: 100, charging: false, charged: true, powerState: kIOPSACPowerValue))
        XCTAssertEqual(full?.state, "Full")
        XCTAssertEqual(full?.isCharging, false)
    }

    func testMissingFlagsDefaultToNotCharging() {
        let reading = BatteryMetrics.reading(from: description())
        XCTAssertEqual(reading?.isCharging, false)
        XCTAssertEqual(reading?.state, "Unknown")
    }

    func testSourcesWithoutUsableCapacityAreSkipped() {
        XCTAssertNil(BatteryMetrics.reading(from: description(current: nil)))
        XCTAssertNil(BatteryMetrics.reading(from: description(max: nil)))
        XCTAssertNil(BatteryMetrics.reading(from: description(max: 0)))
        XCTAssertNil(BatteryMetrics.reading(from: [:]))
    }

    // MARK: - Health

    func testHealthIsFullChargeOverDesignCapacity() {
        XCTAssertEqual(BatteryMetrics.health(currentCapacity: 4_382, designCapacity: 5_103), 86)
        XCTAssertEqual(BatteryMetrics.health(currentCapacity: 5_103, designCapacity: 5_103), 100)
    }

    func testHealthIsCappedAtOneHundred() {
        // A fresh battery can report more than its design capacity.
        XCTAssertEqual(BatteryMetrics.health(currentCapacity: 5_300, designCapacity: 5_103), 100)
    }

    func testUnknownCapacityReadsAsZeroHealth() {
        XCTAssertEqual(BatteryMetrics.health(currentCapacity: 0, designCapacity: 5_103), 0)
        XCTAssertEqual(BatteryMetrics.health(currentCapacity: 4_000, designCapacity: 0), 0)
        XCTAssertEqual(BatteryMetrics.health(currentCapacity: -1, designCapacity: -1), 0)
    }

    // MARK: - Live

    func testLiveSampleIsInRange() {
        let s = BatteryMetrics().sample()
        XCTAssertTrue((0 ... 100).contains(s.level))
        XCTAssertTrue(["Charging", "Full", "Discharging", "AC Power", "Unknown"].contains(s.state), s.state)
        XCTAssertTrue((0 ... 100).contains(s.health))
        XCTAssertGreaterThanOrEqual(s.cycleCount, 0)
    }
}
