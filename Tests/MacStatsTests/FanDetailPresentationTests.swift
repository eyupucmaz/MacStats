import XCTest
@testable import MacStats

final class FanDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let turkish = Locale(identifier: "tr_TR")

    func testTitlesNumberFansOnlyWhenThereAreSeveral() {
        XCTAssertEqual(FanDetailPresentation.title(index: 0, fanCount: 1), "Fan")
        XCTAssertEqual(FanDetailPresentation.title(index: 0, fanCount: 2), "Fan 1")
        XCTAssertEqual(FanDetailPresentation.title(index: 1, fanCount: 2), "Fan 2")
    }

    func testSeriesAddTheSecondFanOnlyWhenThereIsOne() {
        XCTAssertEqual(FanDetailPresentation.seriesIDs(fanCount: 1), [MetricSeriesID.fanRPM])
        XCTAssertEqual(FanDetailPresentation.seriesIDs(fanCount: 3), [MetricSeriesID.fanRPM, "fan.rpm.1"])
    }

    func testRowsShowOnlyReportedValues() {
        let full = FanDetail(index: 0, current: 2610, minimum: 2317, maximum: 6550, target: 2609)
        let rows = FanDetailPresentation.rows(full, locale: english)
        XCTAssertEqual(rows.map(\.label), ["Minimum", "Maximum", "Target"])
        XCTAssertEqual(rows.map(\.value), ["2317 RPM", "6550 RPM", "2609 RPM"])
        XCTAssertEqual(rows[0].spoken, "2317 revolutions per minute")

        let partial = FanDetail(index: 0, current: 2610, maximum: 6550)
        XCTAssertEqual(FanDetailPresentation.rows(partial, locale: english).map(\.label), ["Maximum"])
    }

    func testShareOfMaximum() {
        let fan = FanDetail(index: 0, current: 2620, maximum: 6550)
        let share = FanDetailPresentation.shareOfMaximum(fan, locale: english)
        XCTAssertEqual(share?.text, "40% of max")
        XCTAssertEqual(share?.spoken, "40 percent of maximum speed")
        XCTAssertNil(FanDetailPresentation.shareOfMaximum(FanDetail(index: 0, current: 2620), locale: english))
    }

    func testHeadlineUsesTheCardForTheFirstFan() {
        let report = FanDetailReport(count: 2, fans: [
            FanDetail(index: 0, current: 2000),
            FanDetail(index: 1, current: 2100),
        ])
        XCTAssertEqual(FanDetailPresentation.headline(cardRPM: 1990, report: report).map(\.rpm), [1990, 2100])
        XCTAssertEqual(FanDetailPresentation.headline(cardRPM: nil, report: report).map(\.rpm), [2000, 2100])
        XCTAssertEqual(FanDetailPresentation.headline(cardRPM: 1990, report: nil).map(\.rpm), [1990])
        XCTAssertEqual(FanDetailPresentation.headline(cardRPM: nil, report: nil), [])

        let silent = FanDetailReport(count: 2, fans: [FanDetail(index: 0, current: 2000),
                                                      FanDetail(index: 1, maximum: 6000)])
        XCTAssertEqual(FanDetailPresentation.headline(cardRPM: nil, report: silent).map(\.index), [0],
                       "a fan without a current speed is left out, not shown as 0")
    }

    func testTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(FanDetailPresentation.title(index: 1, fanCount: 2), "Fan 2")
            let fan = FanDetail(index: 0, current: 2620, minimum: 2317, maximum: 6550)
            XCTAssertEqual(FanDetailPresentation.rows(fan, locale: turkish).map(\.label), ["En düşük", "En yüksek"])
            XCTAssertEqual(FanDetailPresentation.shareOfMaximum(fan, locale: turkish)?.text, "en yüksek hızın %40 kadarı")
        }
    }
}
