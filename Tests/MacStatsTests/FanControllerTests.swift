import XCTest
@testable import MacStats

/// Contract tests for `FanController`.
///
/// These tests deliberately avoid asserting anything that depends on the
/// hardware they run on: a fanless Mac, a CI VM without SMC access and a
/// MacBook Pro with two fans must all pass. Only the shape of the public
/// API and its clamping/state invariants are exercised.
@MainActor
final class FanControllerTests: XCTestCase {

    private var controller: FanController { FanController.shared }

    // MARK: - Singleton

    func testSharedReturnsTheSameInstance() {
        XCTAssertTrue(FanController.shared === FanController.shared)
    }

    // MARK: - FanMode

    func testFanModeRawValuesAreStable() {
        XCTAssertEqual(FanController.FanMode.auto.rawValue, "Auto")
        XCTAssertEqual(FanController.FanMode.silent.rawValue, "Silent")
        XCTAssertEqual(FanController.FanMode.balanced.rawValue, "Balanced")
        XCTAssertEqual(FanController.FanMode.max.rawValue, "Max")
        XCTAssertEqual(FanController.FanMode.custom.rawValue, "Custom")
    }

    func testFanModeAllCasesCountIsStable() {
        XCTAssertEqual(FanController.FanMode.allCases.count, 5)
    }

    func testFanModeAllCasesRawValueSet() {
        let raw = Set(FanController.FanMode.allCases.map(\.rawValue))
        XCTAssertEqual(raw, ["Auto", "Silent", "Balanced", "Max", "Custom"])
    }

    func testFanModeIsRoundTrippableThroughItsRawValue() {
        for mode in FanController.FanMode.allCases {
            XCTAssertEqual(FanController.FanMode(rawValue: mode.rawValue), mode)
        }
    }

    func testFanModeIdentifierMatchesRawValue() {
        for mode in FanController.FanMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    // MARK: - Speed bounds

    func testSpeedBoundsAreSaneAndOrdered() {
        XCTAssertGreaterThanOrEqual(controller.minSpeed, 0)
        XCTAssertGreaterThan(controller.maxSpeed, controller.minSpeed)
    }

    func testCurrentFanSpeedIsNeverNegative() {
        XCTAssertGreaterThanOrEqual(controller.currentFanSpeed, 0)
    }

    // MARK: - setCustomSpeed clamping

    func testSetCustomSpeedClampsAboveMaximum() {
        let controller = self.controller
        controller.setCustomSpeed(controller.maxSpeed + 10_000)
        XCTAssertEqual(controller.customSpeed, controller.maxSpeed)
    }

    func testSetCustomSpeedClampsBelowMinimum() {
        let controller = self.controller
        controller.setCustomSpeed(controller.minSpeed - 10_000)
        XCTAssertEqual(controller.customSpeed, controller.minSpeed)
    }

    func testSetCustomSpeedClampsNegativeInput() {
        let controller = self.controller
        controller.setCustomSpeed(-1)
        XCTAssertEqual(controller.customSpeed, controller.minSpeed)

        controller.setCustomSpeed(Int.min / 2)
        XCTAssertEqual(controller.customSpeed, controller.minSpeed)
    }

    func testSetCustomSpeedClampsExtremeInput() {
        let controller = self.controller
        controller.setCustomSpeed(Int.max / 2)
        XCTAssertEqual(controller.customSpeed, controller.maxSpeed)
    }

    func testSetCustomSpeedPreservesInRangeValue() {
        let controller = self.controller
        let midpoint = controller.minSpeed + (controller.maxSpeed - controller.minSpeed) / 2
        controller.setCustomSpeed(midpoint)
        XCTAssertEqual(controller.customSpeed, midpoint)
    }

    func testSetCustomSpeedAcceptsExactBounds() {
        let controller = self.controller
        controller.setCustomSpeed(controller.minSpeed)
        XCTAssertEqual(controller.customSpeed, controller.minSpeed)

        controller.setCustomSpeed(controller.maxSpeed)
        XCTAssertEqual(controller.customSpeed, controller.maxSpeed)
    }

    func testCustomSpeedAlwaysStaysWithinBoundsForArbitraryInput() {
        let controller = self.controller
        for candidate in [-9_999, -1, 0, 1, 500, 3_000, 12_000, 100_000] {
            controller.setCustomSpeed(candidate)
            XCTAssertGreaterThanOrEqual(controller.customSpeed, controller.minSpeed)
            XCTAssertLessThanOrEqual(controller.customSpeed, controller.maxSpeed)
        }
    }

    // MARK: - Mode switching

    func testSetFanModeUpdatesPublishedMode() {
        let controller = self.controller
        for mode in FanController.FanMode.allCases {
            controller.setFanMode(mode)
            XCTAssertEqual(controller.fanMode, mode)
        }
        controller.setFanMode(.auto)
    }

    func testSetFanModeIsIdempotent() {
        let controller = self.controller
        controller.setFanMode(.balanced)
        controller.setFanMode(.balanced)
        XCTAssertEqual(controller.fanMode, .balanced)
        controller.setFanMode(.auto)
    }

    /// Switching modes must never leave the controller reporting a negative
    /// speed, whether or not the SMC write actually succeeded.
    func testSetFanModeKeepsCurrentSpeedNonNegative() {
        let controller = self.controller
        for mode in FanController.FanMode.allCases {
            controller.setFanMode(mode)
            XCTAssertGreaterThanOrEqual(controller.currentFanSpeed, 0)
        }
        controller.setFanMode(.auto)
    }

    // MARK: - Availability reporting

    /// Control can only be available if there is actually a fan to control.
    /// On a fanless Mac both flags are false; the app must not claim it can
    /// drive a fan that does not exist.
    func testControlIsNotAvailableWithoutAFan() {
        if !controller.isFanPresent {
            XCTAssertFalse(controller.isControlAvailable)
        }
    }

    /// `lastError` is a diagnostic string, not a crash: reading it must be safe
    /// and it must not be an empty string when present.
    func testLastErrorIsEitherNilOrNonEmpty() {
        if let error = controller.lastError {
            XCTAssertFalse(error.isEmpty)
        }
    }

    // MARK: - Idempotent operations

    func testRefreshIsSafeToCallRepeatedly() {
        let controller = self.controller
        for _ in 0 ..< 5 {
            controller.refresh()
        }
        XCTAssertGreaterThanOrEqual(controller.currentFanSpeed, 0)
    }

    func testRestoreAutomaticControlIsSafeToCallRepeatedly() {
        let controller = self.controller
        controller.setFanMode(.max)
        controller.restoreAutomaticControl()
        controller.restoreAutomaticControl()
        XCTAssertGreaterThanOrEqual(controller.currentFanSpeed, 0)
        controller.setFanMode(.auto)
    }
}
