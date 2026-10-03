import XCTest
@testable import MacStats

final class AudioTabPollingPolicyTests: XCTestCase {
    func testMenuBarMetricsAlwaysPoll() {
        for shown in [true, false] {
            for tab in [PopoverTab.system, .audio] {
                XCTAssertTrue(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: true, popoverShown: shown, selectedTab: tab))
            }
        }
    }

    func testStaticGlyphPollsOnlyWhileTheSystemTabIsVisible() {
        XCTAssertTrue(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: false, popoverShown: true, selectedTab: .system))
        XCTAssertFalse(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: false, popoverShown: true, selectedTab: .audio))
        XCTAssertFalse(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: false, popoverShown: false, selectedTab: .system))
        XCTAssertFalse(StatsPollingPolicy.shouldPoll(showsMetricsInMenuBar: false, popoverShown: false, selectedTab: .audio))
    }
}
