import XCTest
@testable import MacStats

/// The first-run hint against a throwaway `UserDefaults` suite, the way
/// `AppSettingsTests` does it.
final class OnboardingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MacStatsTests.Onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshInstallShowsTheHintAndOpensThePopoverOnce() {
        let onboarding = Onboarding(defaults: defaults)

        XCTAssertTrue(onboarding.isHintVisible)
        XCTAssertTrue(onboarding.consumeAutoOpen())
        XCTAssertFalse(onboarding.consumeAutoOpen(), "the popover opens by itself only once")
    }

    func testAutoOpenIsRememberedAcrossLaunches() {
        XCTAssertTrue(Onboarding(defaults: defaults).consumeAutoOpen())

        let relaunched = Onboarding(defaults: defaults)
        XCTAssertFalse(relaunched.consumeAutoOpen())
        XCTAssertTrue(relaunched.isHintVisible, "an undismissed hint stays until the user dismisses it")
    }

    func testDismissingHidesTheHintForGood() {
        let onboarding = Onboarding(defaults: defaults)
        _ = onboarding.consumeAutoOpen()

        onboarding.dismissHint()

        XCTAssertFalse(onboarding.isHintVisible)
        XCTAssertFalse(Onboarding(defaults: defaults).isHintVisible)
    }

    func testADismissedHintNeverOpensThePopover() {
        Onboarding(defaults: defaults).dismissHint()

        let relaunched = Onboarding(defaults: defaults)
        XCTAssertFalse(relaunched.isHintVisible)
        XCTAssertFalse(relaunched.consumeAutoOpen())
    }
}
