import XCTest
@testable import MacStats

/// `FanDetailReader` against a scripted SMC: nothing here opens the real one.
final class FanDetailReaderTests: XCTestCase {

    final class FakeFans: FanDetailSource {
        var isAvailable = true
        var count: Int?
        /// "F<n><suffix>" → RPM.
        var values: [String: Int] = [:]
        private(set) var reads: [String] = []

        func fanCount() -> Int? { count }

        func rpm(fan index: Int, _ value: SMCService.FanValue) -> Int? {
            let key = "F\(index)\(value.rawValue)"
            reads.append(key)
            return values[key]
        }
    }

    func testReadsEveryValueOfEveryFan() {
        let fans = FakeFans()
        fans.count = 2
        fans.values = ["F0Ac": 2610, "F0Mn": 2317, "F0Mx": 6550, "F0Tg": 2609,
                       "F1Ac": 2400, "F1Mn": 2200, "F1Mx": 6000, "F1Tg": 2400]
        let report = FanDetailReader.read(from: fans)
        XCTAssertEqual(report.count, 2)
        XCTAssertFalse(report.isFanless)
        XCTAssertEqual(report.fans, [
            FanDetail(index: 0, current: 2610, minimum: 2317, maximum: 6550, target: 2609),
            FanDetail(index: 1, current: 2400, minimum: 2200, maximum: 6000, target: 2400),
        ])
    }

    func testMissingKeysStayNilAndAZeroMaximumIsDropped() {
        let fans = FakeFans()
        fans.count = 1
        fans.values = ["F0Ac": 0, "F0Mx": 0]
        let fan = FanDetailReader.read(from: fans).fans.first
        XCTAssertEqual(fan, FanDetail(index: 0, current: 0, minimum: nil, maximum: nil, target: nil),
                       "a stopped fan reads 0 RPM; a maximum of 0 is not a speed")
        XCTAssertNil(fan?.fractionOfMaximum)
    }

    func testZeroFansIsFanless() {
        let fans = FakeFans()
        fans.count = 0
        let report = FanDetailReader.read(from: fans)
        XCTAssertTrue(report.isFanless)
        XCTAssertEqual(fans.reads, [], "no fan keys are read when the SMC says there are none")
    }

    func testWithoutFanCountTheReadableFansAreCounted() {
        let fans = FakeFans()
        fans.values = ["F0Ac": 1800, "F1Ac": 1900, "F3Ac": 2000]
        let report = FanDetailReader.read(from: fans)
        XCTAssertEqual(report.count, 2, "counting stops at the first fan that does not read")
        XCTAssertEqual(report.fans.map(\.current), [1800, 1900])
    }

    func testWithoutAnyFanKeysAnOpenSMCMeansFanless() {
        let fans = FakeFans()
        XCTAssertTrue(FanDetailReader.read(from: fans).isFanless)

        fans.isAvailable = false
        let report = FanDetailReader.read(from: fans)
        XCTAssertFalse(report.isFanless, "a closed SMC says nothing about fans")
        XCTAssertNil(report.count)
        XCTAssertEqual(report.fans, [])
    }

    func testAFanWithoutAnyReadingIsLeftOut() {
        let fans = FakeFans()
        fans.count = 2
        fans.values = ["F0Ac": 2000]
        let report = FanDetailReader.read(from: fans)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.fans.map(\.index), [0])
    }

    func testGarbageFanCountIsBounded() {
        let fans = FakeFans()
        fans.count = 200
        _ = FanDetailReader.read(from: fans)
        XCTAssertEqual(Set(fans.reads.map { $0.dropFirst().prefix(1) }).count, FanDetailReader.maximumFans)
    }

    func testFractionOfMaximumIsClamped() {
        XCTAssertEqual(FanDetail(index: 0, current: 2000, maximum: 8000).fractionOfMaximum, 0.25)
        XCTAssertEqual(FanDetail(index: 0, current: 9000, maximum: 6000).fractionOfMaximum, 1)
        XCTAssertNil(FanDetail(index: 0, current: nil, maximum: 6000).fractionOfMaximum)
        XCTAssertNil(FanDetail(index: 0, current: 2000, maximum: nil).fractionOfMaximum)
    }
}
