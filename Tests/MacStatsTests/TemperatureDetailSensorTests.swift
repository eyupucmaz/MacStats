import XCTest
@testable import MacStats

/// The sensor catalogue, the reader's plausibility filter and fallback, the session
/// range and the thermal-state timeline. Nothing here opens the SMC.
final class TemperatureDetailSensorTests: XCTestCase {

    // MARK: - Chip family

    func testChipFamilyFromBrandString() {
        XCTAssertEqual(TemperatureChipFamily(chipName: "Apple M1"), .m1)
        XCTAssertEqual(TemperatureChipFamily(chipName: "Apple M2 Max"), .m2)
        XCTAssertEqual(TemperatureChipFamily(chipName: "Apple M3 Pro"), .m3)
        XCTAssertEqual(TemperatureChipFamily(chipName: "Apple M4 Ultra"), .m4)
        XCTAssertEqual(TemperatureChipFamily(chipName: "Apple M5"), .m5)
        XCTAssertEqual(TemperatureChipFamily(chipName: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"), .intel)
    }

    func testUnknownChipsAreNotMapped() {
        XCTAssertNil(TemperatureChipFamily(chipName: nil))
        XCTAssertNil(TemperatureChipFamily(chipName: ""))
        XCTAssertNil(TemperatureChipFamily(chipName: "Apple M6"))
        XCTAssertNil(TemperatureChipFamily(chipName: "Apple M12"), "M12 is not M1")
        XCTAssertNil(TemperatureChipFamily(chipName: "Apple A18 Pro"))
        XCTAssertNil(TemperatureChipFamily(chipName: "VirtualApple @ 2.50GHz"))
    }

    // MARK: - Catalogue

    func testEveryFamilyHasValidUniqueKeysInPageOrder() {
        for family in TemperatureChipFamily.allCases {
            let sensors = TemperatureSensorCatalog.sensors(for: family)
            XCTAssertFalse(sensors.isEmpty, "\(family)")
            XCTAssertEqual(Set(sensors.map(\.key)).count, sensors.count, "duplicate key in \(family)")
            for sensor in sensors {
                XCTAssertEqual(sensor.key.utf8.count, 4, "\(sensor.key) is not a four-character SMC key")
                XCTAssertTrue(sensor.key.hasPrefix("T"), "\(sensor.key) is not a temperature key")
            }
            XCTAssertEqual(sensors.map(\.group), sensors.map(\.group).sorted(), "\(family) lists groups out of order")
        }
    }

    func testAppleSiliconFamiliesSplitCoreTypesAndIntelDoesNot() {
        for family in [TemperatureChipFamily.m1, .m2, .m3, .m4, .m5] {
            let groups = Set(TemperatureSensorCatalog.sensors(for: family).map(\.group))
            XCTAssertTrue(groups.isSuperset(of: [.performanceCores, .efficiencyCores, .gpu, .battery, .storage]), "\(family)")
            XCTAssertFalse(groups.contains(.cpu), "\(family)")
        }
        let intel = Set(TemperatureSensorCatalog.sensors(for: .intel).map(\.group))
        XCTAssertTrue(intel.contains(.cpu))
        XCTAssertFalse(intel.contains(.performanceCores))
    }

    func testM5ListsTheKeysConfirmedOnHardware() {
        let m5 = TemperatureSensorCatalog.sensors(for: .m5)
        func keys(_ group: TemperatureSensorGroup) -> [String] { m5.filter { $0.group == group }.map(\.key) }
        XCTAssertEqual(keys(.performanceCores).count, 8)
        XCTAssertEqual(keys(.efficiencyCores), ["Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"])
        XCTAssertEqual(keys(.battery), ["TB0T", "TB1T", "TB2T"])
        XCTAssertTrue(keys(.storage).contains("TH0x"))
    }

    // MARK: - Reader

    private final class FakeSensors: TemperatureSensorSource {
        var values: [String: Double] = [:]
        var primaryKey: String?
        func temperature(key: String) -> Double? { values[key] }
    }

    private let sensors = [TemperatureSensor(key: "Tp00", group: .performanceCores),
                           TemperatureSensor(key: "Tp0p", group: .efficiencyCores),
                           TemperatureSensor(key: "TB0T", group: .battery),
                           TemperatureSensor(key: "Tz11", group: .soc)]

    func testReaderKeepsOnlyPlausibleReadings() {
        let fake = FakeSensors()
        fake.values = ["Tp00": 93.5, "Tp0p": 80, "TB0T": 33.3, "Tz11": 0]
        let report = TemperatureSensorReader.read(sensors, from: fake)
        XCTAssertTrue(report.isMapped)
        XCTAssertEqual(report.readings.map(\.sensor.key), ["Tp00", "Tp0p", "TB0T"], "0 °C is not a reading")
        XCTAssertEqual(report.readings.first?.celsius, 93.5)

        fake.values["Tp00"] = 130
        XCTAssertFalse(TemperatureSensorReader.read(sensors, from: fake).readings.contains { $0.sensor.key == "Tp00" })
    }

    func testUnmappedOrUnreadableMacsFallBackToTheCardsSensor() {
        let fake = FakeSensors()
        fake.primaryKey = "Tp09"
        fake.values = ["Tp09": 51]
        let unknown = TemperatureSensorReader.read([], from: fake)
        XCTAssertFalse(unknown.isMapped)
        XCTAssertEqual(unknown.readings, [TemperatureSensorReading(sensor: TemperatureSensor(key: "Tp09", group: .cpu),
                                                                  celsius: 51)])

        let nothingReads = TemperatureSensorReader.read(sensors, from: fake)
        XCTAssertFalse(nothingReads.isMapped)
        XCTAssertEqual(nothingReads.readings.map(\.sensor.key), ["Tp09"])

        fake.values["Tp09"] = 200
        XCTAssertEqual(TemperatureSensorReader.read([], from: fake), TemperatureDetailReport(isMapped: false, readings: []))
        fake.primaryKey = nil
        XCTAssertEqual(TemperatureSensorReader.read([], from: fake).readings, [])
    }

    // MARK: - Session range

    func testSessionRangeWidensPerSensor() {
        let cpu = TemperatureSensor(key: "Tp00", group: .performanceCores)
        let gpu = TemperatureSensor(key: "Tg04", group: .gpu)
        var session = TemperatureSessionRange()
        session.record([.init(sensor: cpu, celsius: 60), .init(sensor: gpu, celsius: 50)])
        session.record([.init(sensor: cpu, celsius: 72.5)])
        session.record([.init(sensor: cpu, celsius: 55), .init(sensor: gpu, celsius: 49)])
        XCTAssertEqual(session.range(for: "Tp00"), 55...72.5)
        XCTAssertEqual(session.range(for: "Tg04"), 49...50)
        XCTAssertNil(session.range(for: "TB0T"))
    }

    // MARK: - Thermal timeline

    func testTimelineRecordsChangesAndVisitEnds() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var timeline = ThermalStateTimeline()
        timeline.record(nil, at: t0)
        XCTAssertEqual(timeline.entries, [], "an end marker before any state means nothing")
        timeline.record(.nominal, at: t0)
        timeline.record(.nominal, at: t0.addingTimeInterval(5))
        timeline.record(.fair, at: t0.addingTimeInterval(10))
        timeline.record(nil, at: t0.addingTimeInterval(20))
        timeline.record(nil, at: t0.addingTimeInterval(25))
        timeline.record(.fair, at: t0.addingTimeInterval(60))
        XCTAssertEqual(timeline.entries.map(\.state), [.nominal, .fair, nil, .fair])
        XCTAssertEqual(timeline.entries.map { $0.date.timeIntervalSince(t0) }, [0, 10, 20, 60])
    }

    func testTimelineKeepsOnlyTheWindowPlusTheEntryItStartsIn() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var timeline = ThermalStateTimeline()
        timeline.record(.nominal, at: t0, window: 100)
        timeline.record(.fair, at: t0.addingTimeInterval(50), window: 100)
        timeline.record(.serious, at: t0.addingTimeInterval(80), window: 100)
        timeline.record(.nominal, at: t0.addingTimeInterval(200), window: 100)
        XCTAssertEqual(timeline.entries.map(\.state), [.serious, .nominal],
                       "the serious stretch is still on screen at the start of the window")

        timeline.record(.fair, at: t0, window: 100)
        XCTAssertEqual(timeline.entries.map(\.state), [.fair], "a clock that went backwards starts over")
    }
}
