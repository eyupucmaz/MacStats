import XCTest
@testable import MacStats

/// Text, rows, the power-state band and the power split of the battery detail page.
final class BatteryDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let turkish = Locale(identifier: "tr_TR")

    private var battery: BatteryDetail.Battery {
        var battery = BatteryDetail.Battery(level: 80, state: .discharging)
        battery.watts = -16.9
        battery.voltage = 13.022
        battery.temperature = 30.66
        battery.cycleCount = 49
        battery.designCycleCount = 1_000
        battery.maximumCapacity = 5_739
        battery.designCapacity = 6_249
        battery.health = 92
        battery.condition = .normal
        return battery
    }

    // MARK: - Format

    func testSignedWatts() {
        XCTAssertEqual(BatteryDetailFormat.signedWatts(12.34, locale: english), "+12 W")
        XCTAssertEqual(BatteryDetailFormat.signedWatts(-8.14, locale: english), "\u{2212}8.1 W")
        XCTAssertEqual(BatteryDetailFormat.signedWatts(-8.14, locale: turkish), "\u{2212}8,1 W")
        XCTAssertEqual(BatteryDetailFormat.signedWatts(0, locale: english), "0 W")
        XCTAssertEqual(BatteryDetailFormat.signedWatts(-0.02, locale: english), "0 W", "no signed zero")
        L10n.$language.withValue("en") {
            XCTAssertEqual(BatteryDetailFormat.spokenWatts(12.3, locale: english), "12 watts into the battery")
            XCTAssertEqual(BatteryDetailFormat.spokenWatts(-8.1, locale: english), "8.1 watts from the battery")
        }
    }

    func testDurations() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(BatteryDetailFormat.duration(minutes: 135).text, "2 h 15 min")
            XCTAssertEqual(BatteryDetailFormat.duration(minutes: 135).spoken, "2 hours, 15 minutes")
            XCTAssertEqual(BatteryDetailFormat.duration(minutes: 61).spoken, "1 hour, 1 minute")
            XCTAssertEqual(BatteryDetailFormat.duration(minutes: 45).text, "45 min")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(BatteryDetailFormat.duration(minutes: 135).text, "2 sa 15 dk")
        }
    }

    func testStateTitlesStartWithACapital() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(BatteryDetailFormat.stateTitle(.charging, locale: english), "Charging")
            XCTAssertEqual(BatteryDetailFormat.stateTitle(nil, locale: english), "Unknown")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(BatteryDetailFormat.stateTitle(.charging, locale: turkish), "Şarj oluyor")
            XCTAssertEqual(BatteryDetailFormat.powerStateTitle(.onBattery, locale: turkish), "Pilden çalışıyor")
        }
    }

    // MARK: - Rows

    func testHealthRows() {
        L10n.$language.withValue("en") {
            let rows = BatteryDetailRow.health(battery, locale: english)
            XCTAssertEqual(rows.map(\.label), ["Condition", "Health", "Maximum capacity", "Design capacity",
                                               "Cycle count", "Temperature", "Voltage"])
            XCTAssertEqual(rows.map(\.value), ["Normal", "92%", "5739 mAh", "6249 mAh", "49 of 1000", "30.7°C", "13.02 V"])
            XCTAssertEqual(rows[2].spoken, "5739 milliampere-hours")
            XCTAssertEqual(rows[6].spoken, "13.02 volts")
        }
    }

    func testUnknownHealthValuesAreHidden() {
        let rows = BatteryDetailRow.health(BatteryDetail.Battery(level: 50, state: .full), locale: english)
        XCTAssertEqual(rows, [])
        var cycles = BatteryDetail.Battery(level: 50, state: .full)
        cycles.cycleCount = 12
        XCTAssertEqual(BatteryDetailRow.health(cycles, locale: english).map(\.value), ["12"])
    }

    func testPowerRowsOnALaptop() {
        L10n.$language.withValue("en") {
            var detail = BatteryDetail(battery: battery, powerSource: .ac, adapterConnected: true,
                                       adapter: PowerAdapterInfo(name: "70W USB-C Power Adapter", watts: 68))
            XCTAssertEqual(BatteryDetailRow.power(detail, locale: english).map(\.value),
                           ["Connected", "70W USB-C Power Adapter", "68 W"])
            detail.adapterConnected = false
            detail.adapter = nil
            XCTAssertEqual(BatteryDetailRow.power(detail, locale: english).map(\.value), ["Not connected"])
        }
    }

    func testPowerRowsOnADesktop() {
        L10n.$language.withValue("en") {
            let detail = BatteryDetail(battery: nil, powerSource: .ac, adapterConnected: true, adapter: nil)
            XCTAssertEqual(BatteryDetailRow.power(detail, locale: english).map(\.label), ["Power source"])
            XCTAssertEqual(BatteryDetailRow.power(detail, locale: english).map(\.value), ["AC power"])
            XCTAssertEqual(BatteryDetailRow.power(BatteryDetail(), locale: english), [])
        }
    }

    // MARK: - Band

    private let end = Date(timeIntervalSince1970: 10_000)

    private func point(_ secondsBeforeEnd: TimeInterval, _ state: BatteryPowerState?) -> MetricPoint {
        MetricPoint(date: end.addingTimeInterval(-secondsBeforeEnd), value: state?.historyValue)
    }

    func testBandMergesRunsAndStopsAtGaps() {
        let points = [point(60, .onBattery), point(58, .onBattery), point(56, .charging),
                      point(54, nil),                              // page closed
                      point(20, .charging), point(18, .pluggedIn)]
        let band = BatteryStateBand(points: points, range: .oneMinute, end: end, interval: 2)
        XCTAssertEqual(band.segments.map(\.state), [.onBattery, .charging, .charging, .pluggedIn])
        XCTAssertEqual(band.segments[0].end, end.addingTimeInterval(-56))
        XCTAssertEqual(band.segments[1].end, end.addingTimeInterval(-54), "a reading ends at the gap marker")
        XCTAssertEqual(band.segments[3].end, end.addingTimeInterval(-16), "the newest reading holds one interval")
        L10n.$language.withValue("en") {
            XCTAssertEqual(band.summary(locale: english), "Charging 40%, AC Power 20%, Discharging 40%")
        }
    }

    func testEmptyBandSaysSo() {
        let band = BatteryStateBand(points: [], range: .fiveMinutes, end: end, interval: 2)
        XCTAssertEqual(band.domain, end.addingTimeInterval(-300)...end)
        L10n.$language.withValue("en") {
            XCTAssertEqual(band.summary(locale: english), "No readings yet")
        }
    }

    // MARK: - Power split

    func testPowerSplitsBySign() {
        let dates = (0..<5).map { end.addingTimeInterval(Double($0)) }
        let series = MetricSeries(id: BatteryDetailSeries.watts, unit: .watts, points: [
            MetricPoint(date: dates[0], value: -10), MetricPoint(date: dates[1], value: -6),
            MetricPoint(date: dates[2], value: nil), MetricPoint(date: dates[3], value: 0),
            MetricPoint(date: dates[4], value: 20),
        ])
        let split = BatteryPowerSplit(series)
        XCTAssertEqual(split.charging.points.map(\.value), [nil, nil, nil, 0, 20])
        XCTAssertEqual(split.discharging.points.map(\.value), [10, 6, nil, nil, nil])
        XCTAssertEqual(split.drawn.map(\.id), [BatteryPowerSplit.chargingID, BatteryPowerSplit.dischargingID])
        XCTAssertEqual(BatteryPowerSplit.statistics(split.discharging), SeriesStatistics(min: 6, average: 8, max: 10))
        XCTAssertEqual(BatteryPowerSplit.statistics(split.charging), SeriesStatistics(min: 0, average: 10, max: 20))
    }

    func testPowerSplitDrawsOnlyHalvesWithData() {
        let split = BatteryPowerSplit(MetricSeries(id: BatteryDetailSeries.watts, unit: .watts,
                                                   points: [MetricPoint(date: end, value: -3)]))
        XCTAssertEqual(split.drawn.map(\.id), [BatteryPowerSplit.dischargingID])
        XCTAssertNil(BatteryPowerSplit.statistics(split.charging))
        XCTAssertEqual(BatteryPowerSplit(nil).drawn, [])
    }
}
