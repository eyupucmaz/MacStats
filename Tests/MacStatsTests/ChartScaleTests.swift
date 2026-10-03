import Foundation
import XCTest
@testable import MacStats

/// Axis domains and ticks per unit, and time-axis ticks per range.
final class ChartScaleTests: XCTestCase {
    private func assertScale(_ scale: ChartValueScale, _ domain: ClosedRange<Double>, ticks: [Double],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(scale.domain.lowerBound, domain.lowerBound, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(scale.domain.upperBound, domain.upperBound, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(scale.ticks.count, ticks.count, "ticks \(scale.ticks)", file: file, line: line)
        for (tick, expected) in zip(scale.ticks, ticks) {
            XCTAssertEqual(tick, expected, accuracy: 1e-9, file: file, line: line)
        }
    }

    func testPercentIsAlwaysZeroToHundred() {
        for maximum in [nil, 3.0, 64, 140] {
            assertScale(.make(unit: .percent, minimum: 0, maximum: maximum), 0...100, ticks: [0, 25, 50, 75, 100])
        }
    }

    func testRatesAndSizesStartAtZeroWithNiceSteps() {
        assertScale(.make(unit: .bytesPerSecond, minimum: 0, maximum: 1_200_000),
                    0...1_500_000, ticks: [0, 500_000, 1_000_000, 1_500_000])
        assertScale(.make(unit: .bytes, minimum: 2_000_000_000, maximum: 7_400_000_000),
                    0...8_000_000_000, ticks: [0, 2e9, 4e9, 6e9, 8e9])
    }

    func testIdleOrMissingDataStillGetsAReadableAxis() {
        assertScale(.make(unit: .bytesPerSecond, minimum: 0, maximum: 0), 0...1_000, ticks: [0, 500, 1_000])
        assertScale(.make(unit: .bytesPerSecond, minimum: nil, maximum: nil), 0...1_000, ticks: [0, 500, 1_000])
        assertScale(.make(unit: .watts, minimum: 0, maximum: 0.3), 0...1, ticks: [0, 0.5, 1])
        assertScale(.make(unit: .count, minimum: 0, maximum: 2), 0...4, ticks: [0, 1, 2, 3, 4])
    }

    func testTemperatureAndFanSpeedFloatAboveZero() {
        assertScale(.make(unit: .celsius, minimum: 48.3, maximum: 52), 45...60, ticks: [45, 50, 55, 60])
        assertScale(.make(unit: .celsius, minimum: 40, maximum: 85), 40...100, ticks: [40, 60, 80, 100])
        assertScale(.make(unit: .rpm, minimum: 1_800, maximum: 2_600), 1_500...3_000,
                    ticks: [1_500, 2_000, 2_500, 3_000])
        // A fan at rest keeps the axis at zero rather than going negative.
        XCTAssertEqual(ChartValueScale.make(unit: .rpm, minimum: 0, maximum: 0).domain.lowerBound, 0)
    }

    func testCountTicksAreWholeNumbers() {
        let scale = ChartValueScale.make(unit: .count, minimum: 0, maximum: 3)
        XCTAssertTrue(scale.ticks.allSatisfy { $0 == $0.rounded() }, "\(scale.ticks)")
        XCTAssertGreaterThanOrEqual(scale.step, 1)
    }

    func testNiceStepUsesOneTwoFive() {
        XCTAssertEqual(ChartValueScale.niceStep(1), 1)
        XCTAssertEqual(ChartValueScale.niceStep(1.3), 2)
        XCTAssertEqual(ChartValueScale.niceStep(3), 5)
        XCTAssertEqual(ChartValueScale.niceStep(7), 10)
        XCTAssertEqual(ChartValueScale.niceStep(300_000), 500_000)
        XCTAssertEqual(ChartValueScale.niceStep(0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ChartValueScale.niceStep(0), 1)
        XCTAssertEqual(ChartValueScale.niceStep(.nan), 1)
    }

    func testTimeTicksSitOnWholeStepsInsideTheRange() {
        let end = Date(timeIntervalSince1970: 1_790_000_000)
        for range in HistoryRange.allCases {
            let scale = ChartTimeScale.make(range: range, end: end)
            let step = ChartTimeScale.tickStep(for: range)
            XCTAssertEqual(scale.domain, end.addingTimeInterval(-range.duration)...end)
            XCTAssertGreaterThanOrEqual(scale.ticks.count, 2, "\(range)")
            XCTAssertLessThanOrEqual(scale.ticks.count, 5, "\(range)")
            for tick in scale.ticks {
                XCTAssertTrue(scale.domain.contains(tick))
                XCTAssertEqual(tick.timeIntervalSince1970.truncatingRemainder(dividingBy: step), 0)
            }
            XCTAssertEqual(scale.showsSeconds, range == .oneMinute)
        }
        XCTAssertEqual(ChartTimeScale.make(range: .oneMinute, end: end).ticks.map { $0.timeIntervalSince(end) },
                       [-60, -40, -20, 0])
    }
}
