import IOKit.ps
import XCTest
@testable import MacStats

/// `BatteryDetail.make` and its derivations, from hand-built IOPS and AppleSmartBattery
/// readings (values taken from an Apple M5 MacBook), so no battery is needed.
final class BatteryDetailParsingTests: XCTestCase {

    private func powerSource(level: Int = 80, charging: Bool = false, charged: Bool = false,
                             state: String = kIOPSBatteryPowerValue,
                             extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = [kIOPSCurrentCapacityKey: level, kIOPSMaxCapacityKey: 100,
                                kIOPSIsChargingKey: charging, kIOPSIsChargedKey: charged,
                                kIOPSPowerSourceStateKey: state]
        d.merge(extra) { _, new in new }
        return d
    }

    private let registry: [String: Any] = [
        SmartBatteryKey.voltage: 13_022,
        SmartBatteryKey.amperage: -1_296,
        SmartBatteryKey.temperature: 3_065,
        SmartBatteryKey.cycleCount: 49,
        SmartBatteryKey.designCycleCount: 1_000,
        SmartBatteryKey.designCapacity: 6_249,
        SmartBatteryKey.nominalChargeCapacity: 5_739,
        SmartBatteryKey.rawMaxCapacity: 5_587,
        SmartBatteryKey.permanentFailureStatus: 0,
        SmartBatteryKey.averageTimeToEmpty: 300,
        SmartBatteryKey.averageTimeToFull: 65_535,
        SmartBatteryKey.externalConnected: false,
    ]

    // MARK: - Whole sample

    func testLaptopOnBattery() throws {
        let raw = BatteryDetailRaw(powerSource: powerSource(), providingSource: kIOPSBatteryPowerValue,
                                   timeRemainingEstimate: 4 * 3_600 + 31 * 60, registry: registry, adapter: nil)
        let detail = BatteryDetail.make(raw)
        let battery = try XCTUnwrap(detail.battery)
        XCTAssertEqual(battery.level, 80)
        XCTAssertEqual(battery.state, .discharging)
        XCTAssertEqual(battery.timeRemaining, .untilEmpty(minutes: 271))
        XCTAssertEqual(try XCTUnwrap(battery.watts), -16.877, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(battery.voltage), 13.022, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(battery.temperature), 30.65, accuracy: 0.0001)
        XCTAssertEqual(battery.cycleCount, 49)
        XCTAssertEqual(battery.designCycleCount, 1_000)
        XCTAssertEqual(battery.maximumCapacity, 5_739, "nominal capacity first, like the card")
        XCTAssertEqual(battery.designCapacity, 6_249)
        XCTAssertEqual(battery.health, 92)
        XCTAssertEqual(battery.condition, .normal)
        XCTAssertEqual(detail.powerSource, .battery)
        XCTAssertEqual(detail.adapterConnected, false)
        XCTAssertNil(detail.adapter)
    }

    func testHealthMatchesTheCard() throws {
        let battery = try XCTUnwrap(BatteryDetail.make(BatteryDetailRaw(powerSource: powerSource(), registry: registry)).battery)
        XCTAssertEqual(battery.health, BatteryMetrics.health(currentCapacity: 5_739, designCapacity: 6_249))
    }

    func testRawMaxCapacityIsTheFallback() {
        var registry = registry
        registry[SmartBatteryKey.nominalChargeCapacity] = nil
        let battery = BatteryDetail.make(BatteryDetailRaw(powerSource: powerSource(), registry: registry)).battery
        XCTAssertEqual(battery?.maximumCapacity, 5_587)
        XCTAssertEqual(battery?.health, 89)
    }

    func testLaptopChargingWithAdapter() throws {
        var registry = registry
        registry[SmartBatteryKey.amperage] = 3_000
        registry[SmartBatteryKey.externalConnected] = true
        let raw = BatteryDetailRaw(
            powerSource: powerSource(level: 40, charging: true, state: kIOPSACPowerValue,
                                     extra: [kIOPSTimeToFullChargeKey: 95]),
            providingSource: kIOPSACPowerValue, timeRemainingEstimate: -2, registry: registry,
            adapter: [kIOPSPowerAdapterWattsKey: 68, "Name": "70W USB-C Power Adapter ", "Current": 3_390])
        let detail = BatteryDetail.make(raw)
        XCTAssertEqual(detail.battery?.state, .charging)
        XCTAssertEqual(detail.battery?.timeRemaining, .untilFull(minutes: 95))
        XCTAssertEqual(try XCTUnwrap(detail.battery?.watts), 39.066, accuracy: 0.001)
        XCTAssertEqual(detail.adapterConnected, true)
        XCTAssertEqual(detail.adapter, PowerAdapterInfo(name: "70W USB-C Power Adapter", watts: 68))
        XCTAssertEqual(detail.powerSource, .ac)
    }

    func testDesktopHasNoBatteryButKeepsPowerSourceAndAdapter() {
        let detail = BatteryDetail.make(BatteryDetailRaw(powerSource: nil, providingSource: kIOPSACPowerValue,
                                                         timeRemainingEstimate: -2, registry: nil,
                                                         adapter: [kIOPSPowerAdapterWattsKey: 150]))
        XCTAssertNil(detail.battery)
        XCTAssertEqual(detail.powerSource, .ac)
        XCTAssertEqual(detail.adapter, PowerAdapterInfo(name: nil, watts: 150))
        XCTAssertEqual(detail.adapterConnected, true)
    }

    func testDesktopWithNothingReportedIsEmpty() {
        XCTAssertEqual(BatteryDetail.make(BatteryDetailRaw()), BatteryDetail())
    }

    func testMissingRegistryHidesGaugeValues() throws {
        let battery = try XCTUnwrap(BatteryDetail.make(BatteryDetailRaw(powerSource: powerSource())).battery)
        XCTAssertNil(battery.watts)
        XCTAssertNil(battery.voltage)
        XCTAssertNil(battery.temperature)
        XCTAssertNil(battery.cycleCount)
        XCTAssertNil(battery.maximumCapacity)
        XCTAssertNil(battery.health, "unknown health is hidden, not 0")
        XCTAssertNil(battery.condition)
        XCTAssertNil(battery.timeRemaining)
    }

    func testAdapterIsDroppedWhenTheGaugeSaysUnplugged() {
        let detail = BatteryDetail.make(BatteryDetailRaw(powerSource: powerSource(), registry: registry,
                                                         adapter: [kIOPSPowerAdapterWattsKey: 68]))
        XCTAssertEqual(detail.adapterConnected, false)
        XCTAssertNil(detail.adapter)
    }

    func testConnectionFallsBackToThePowerSourceState() {
        let onAC = BatteryDetail.make(BatteryDetailRaw(powerSource: powerSource(state: kIOPSACPowerValue)))
        XCTAssertEqual(onAC.adapterConnected, true)
        let onBattery = BatteryDetail.make(BatteryDetailRaw(powerSource: powerSource()))
        XCTAssertEqual(onBattery.adapterConnected, false)
    }

    // MARK: - Derivations

    func testAmperageStoredAsUnsigned32BitIsNegative() {
        XCTAssertEqual(BatteryDetail.signed32(4_294_966_000), -1_296)
        XCTAssertEqual(BatteryDetail.signed32(-1_296), -1_296)
        XCTAssertEqual(BatteryDetail.signed32(3_000), 3_000)
        XCTAssertEqual(BatteryDetail.signed32(5_000_000_000), 5_000_000_000)
    }

    func testWattsAreSignedAndSane() {
        XCTAssertEqual(BatteryDetail.watts(millivolts: 12_000, milliamps: 1_000), 12)
        XCTAssertEqual(BatteryDetail.watts(millivolts: 12_000, milliamps: -500), -6)
        XCTAssertEqual(BatteryDetail.watts(millivolts: 12_000, milliamps: 0), 0)
        XCTAssertNil(BatteryDetail.watts(millivolts: nil, milliamps: 100))
        XCTAssertNil(BatteryDetail.watts(millivolts: 12_000, milliamps: nil))
        XCTAssertNil(BatteryDetail.watts(millivolts: 0, milliamps: 100))
        XCTAssertNil(BatteryDetail.watts(millivolts: 12_000, milliamps: 4_294_966_000), "unconverted garbage")
    }

    func testTemperatureIsHundredthsOfADegree() {
        XCTAssertEqual(BatteryDetail.temperature(NSNumber(value: 3_065)), 30.65)
        XCTAssertNil(BatteryDetail.temperature(NSNumber(value: 0)))
        XCTAssertNil(BatteryDetail.temperature(NSNumber(value: 29_815)), "decikelvin or garbage")
        XCTAssertNil(BatteryDetail.temperature("3065"))
        XCTAssertNil(BatteryDetail.temperature(nil))
    }

    func testCondition() {
        // The gauge's failure flag beats IOPS' health, which can read "Check Battery" on Apple silicon.
        XCTAssertEqual(BatteryDetail.condition(healthCondition: "", permanentFailure: 0, health: kIOPSCheckBatteryValue), .normal)
        XCTAssertEqual(BatteryDetail.condition(healthCondition: nil, permanentFailure: 4, health: kIOPSGoodValue), .serviceRecommended)
        XCTAssertEqual(BatteryDetail.condition(healthCondition: kIOPSPermanentFailureValue, permanentFailure: 0, health: nil),
                       .serviceRecommended)
        XCTAssertEqual(BatteryDetail.condition(healthCondition: nil, permanentFailure: nil, health: kIOPSGoodValue), .normal)
        XCTAssertEqual(BatteryDetail.condition(healthCondition: nil, permanentFailure: nil, health: kIOPSPoorValue), .serviceRecommended)
        XCTAssertNil(BatteryDetail.condition(healthCondition: nil, permanentFailure: nil, health: kIOPSCheckBatteryValue))
        XCTAssertNil(BatteryDetail.condition(healthCondition: nil, permanentFailure: nil, health: nil))
    }

    func testTimeToFullPrefersIOPSAndHidesWhileCalculating() {
        func time(_ toFull: Int?, average: Int? = 120) -> BatteryTimeRemaining? {
            BatteryDetail.timeRemaining(state: .charging, estimate: -2, timeToFull: toFull, timeToEmpty: nil,
                                        averageTimeToFull: average, averageTimeToEmpty: nil, gaugeTimeRemaining: nil)
        }
        XCTAssertEqual(time(95), .untilFull(minutes: 95))
        XCTAssertNil(time(-1), "macOS still calculating")
        XCTAssertNil(time(0))
        XCTAssertEqual(time(nil), .untilFull(minutes: 120), "the gauge only when IOPS has no figure")
        XCTAssertNil(time(nil, average: 65_535))
    }

    func testTimeToEmptyPrefersTheSystemEstimate() {
        func time(_ estimate: Double?, _ toEmpty: Int? = 200, average: Int? = 300) -> BatteryTimeRemaining? {
            BatteryDetail.timeRemaining(state: .discharging, estimate: estimate, timeToFull: nil, timeToEmpty: toEmpty,
                                        averageTimeToFull: nil, averageTimeToEmpty: average, gaugeTimeRemaining: nil)
        }
        XCTAssertEqual(time(5_430), .untilEmpty(minutes: 91))
        XCTAssertNil(time(-1), "macOS still calculating")
        XCTAssertEqual(time(nil), .untilEmpty(minutes: 200))
        XCTAssertNil(time(nil, -1))
        XCTAssertEqual(time(nil, nil), .untilEmpty(minutes: 300))
        XCTAssertNil(time(nil, nil, average: 65_535))
    }

    func testNoTimeWhenFullOrOnAC() {
        for state in [BatteryChargeState.full, .acPower, nil] {
            XCTAssertNil(BatteryDetail.timeRemaining(state: state, estimate: 3_600, timeToFull: 10, timeToEmpty: 10,
                                                     averageTimeToFull: 10, averageTimeToEmpty: 10, gaugeTimeRemaining: 10))
        }
    }

    func testAdapterNeedsANameOrWattage() {
        XCTAssertNil(BatteryDetail.adapter(from: nil))
        XCTAssertNil(BatteryDetail.adapter(from: ["Current": 3_000, "Name": "  "]))
        XCTAssertEqual(BatteryDetail.adapter(from: ["Name": "Charger"]), PowerAdapterInfo(name: "Charger", watts: nil))
        XCTAssertEqual(BatteryDetail.adapter(from: [kIOPSPowerAdapterWattsKey: 0]), nil)
    }

    func testStatesMirrorTheCard() {
        for state in [BatteryChargeState.charging, .full, .acPower, .discharging] {
            XCTAssertEqual(BatteryChargeState(engineState: state.engineState), state)
        }
        XCTAssertNil(BatteryChargeState(engineState: "Unknown"))
        XCTAssertEqual(BatteryChargeState.full.powerState, .pluggedIn)
        XCTAssertEqual(BatteryChargeState.discharging.powerState, .onBattery)
        XCTAssertEqual(BatteryPowerState(historyValue: 2), .charging)
        XCTAssertNil(BatteryPowerState(historyValue: 7))
        XCTAssertNil(BatteryPowerState(historyValue: .nan))
    }

    func testPowerSourceKinds() {
        XCTAssertEqual(PowerSourceKind(kIOPSACPowerValue), .ac)
        XCTAssertEqual(PowerSourceKind(kIOPSBatteryPowerValue), .battery)
        XCTAssertEqual(PowerSourceKind("UPS Power"), .ups)
        XCTAssertNil(PowerSourceKind(nil))
    }
}
