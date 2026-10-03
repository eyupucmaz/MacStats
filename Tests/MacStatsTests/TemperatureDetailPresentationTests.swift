import XCTest
@testable import MacStats

final class TemperatureDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let turkish = Locale(identifier: "tr_TR")

    private func reading(_ key: String, _ group: TemperatureSensorGroup, _ celsius: Double) -> TemperatureSensorReading {
        TemperatureSensorReading(sensor: TemperatureSensor(key: key, group: group), celsius: celsius)
    }

    func testGroupsFollowPageOrderAndShowTheirHottestSensor() {
        let report = TemperatureDetailReport(isMapped: true, readings: [
            reading("TB0T", .battery, 33.3),
            reading("Tp00", .performanceCores, 93.5),
            reading("Tp04", .performanceCores, 99.62),
            reading("Tg04", .gpu, 77.7),
        ])
        let groups = TemperatureDetailPresentation.groups(report, session: TemperatureSessionRange(), locale: english)
        XCTAssertEqual(groups.map(\.group), [.performanceCores, .gpu, .battery])
        XCTAssertEqual(groups.map(\.title), ["Performance cores", "GPU", "Battery"])
        XCTAssertEqual(groups[0].hottest, "99.6°C")
        XCTAssertEqual([groups[0].low, groups[0].high], ["93.5°C", "99.6°C"])
        XCTAssertEqual(groups[0].spoken,
                       "Performance cores, hottest 99.6 degrees Celsius, lowest 93.5 degrees Celsius, highest 99.6 degrees Celsius")
        XCTAssertEqual(groups[0].rows.map(\.label), ["Sensor 1", "Sensor 2"])
        XCTAssertEqual(groups[0].rows.map(\.key), ["Tp00", "Tp04"])
    }

    func testRowsShowTheSessionRange() {
        let tp00 = reading("Tp00", .performanceCores, 70)
        var session = TemperatureSessionRange()
        session.record([reading("Tp00", .performanceCores, 55.04), reading("Tp00", .performanceCores, 92)])
        session.record([tp00])
        let row = TemperatureDetailPresentation.groups(.init(isMapped: true, readings: [tp00]), session: session,
                                                       locale: english)[0].rows[0]
        XCTAssertEqual([row.now, row.low, row.high], ["70.0°C", "55.0°C", "92.0°C"])
        XCTAssertEqual(row.spoken, "Sensor 1, 70.0 degrees Celsius, lowest 55.0 degrees Celsius, highest 92.0 degrees Celsius")

        let unrecorded = TemperatureDetailPresentation.groups(.init(isMapped: true, readings: [tp00]),
                                                              session: TemperatureSessionRange(), locale: english)[0].rows[0]
        XCTAssertEqual([unrecorded.low, unrecorded.high], ["70.0°C", "70.0°C"], "the range always includes now")

        let tg = reading("Tg04", .gpu, 60)
        var gpuSession = TemperatureSessionRange()
        gpuSession.record([reading("Tg04", .gpu, 41), reading("Tg0C", .gpu, 88)])
        let gpu = TemperatureDetailPresentation.groups(.init(isMapped: true, readings: [tg, reading("Tg0C", .gpu, 65)]),
                                                       session: gpuSession, locale: english)[0]
        XCTAssertEqual([gpu.hottest, gpu.low, gpu.high], ["65.0°C", "41.0°C", "88.0°C"],
                       "hottest now, then the range of every sensor in the group")
    }

    func testFallbackRowIsNamedAfterItsGroup() {
        let report = TemperatureDetailReport(isMapped: false, readings: [reading("Tp09", .cpu, 51)])
        let groups = TemperatureDetailPresentation.groups(report, session: TemperatureSessionRange(), locale: english)
        XCTAssertEqual(groups.map(\.title), ["CPU"])
        XCTAssertEqual(groups[0].rows.map(\.label), ["CPU"])
    }

    func testGroupTitles() {
        XCTAssertEqual(TemperatureSensorGroup.allCases.map(TemperatureDetailPresentation.title(of:)),
                       ["CPU", "Performance cores", "Efficiency cores", "GPU", "SoC / other", "Battery", "Storage"])
    }

    // MARK: - Thermal band

    func testBandLaysOutKnownStretchesInsideTheRange() {
        let end = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var timeline = ThermalStateTimeline()
        timeline.record(.nominal, at: end.addingTimeInterval(-400))  // starts before the 5 m range
        timeline.record(.fair, at: end.addingTimeInterval(-200))
        timeline.record(nil, at: end.addingTimeInterval(-150))       // page closed
        timeline.record(.nominal, at: end.addingTimeInterval(-50))   // reopened
        let band = ThermalStateBand(timeline: timeline, range: .fiveMinutes, end: end)

        XCTAssertEqual(band.domain, end.addingTimeInterval(-300)...end)
        XCTAssertEqual(band.segments.map(\.level), [.nominal, .fair, .nominal])
        XCTAssertEqual(band.segments.map { $0.start.timeIntervalSince(end) }, [-300, -200, -50])
        XCTAssertEqual(band.segments.map { $0.end.timeIntervalSince(end) }, [-200, -150, 0])
        // 100 s nominal + 50 s now, 50 s fair: the gap is left out.
        XCTAssertEqual(band.summary(locale: english), "Fair 25%, Nominal 75%")
    }

    func testEmptyBand() {
        let band = ThermalStateBand(timeline: ThermalStateTimeline(), range: .oneMinute, end: Date())
        XCTAssertEqual(band.segments, [])
        XCTAssertEqual(band.summary(locale: english), "No readings yet")
    }

    func testTurkish() {
        L10n.$language.withValue("tr") {
            let report = TemperatureDetailReport(isMapped: true, readings: [reading("TH0x", .storage, 46.77)])
            let group = TemperatureDetailPresentation.groups(report, session: TemperatureSessionRange(), locale: turkish)[0]
            XCTAssertEqual(group.title, "Depolama")
            XCTAssertEqual(group.hottest, "46,8°C")
            XCTAssertEqual(group.rows[0].label, "Sensör 1")
            XCTAssertEqual(TemperatureDetailPresentation.title(of: .soc), "SoC / diğer")
        }
    }
}
