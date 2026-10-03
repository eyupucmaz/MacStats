import XCTest
@testable import MacStats

/// The path-based grouping rule of `ProcessIdentity.make`.
final class ProcessIdentityTests: XCTestCase {

    private final class Counter { var value = 0 }

    private let chrome = "/Applications/Google Chrome.app"
    private var renderer: String {
        chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/1.0/Helpers/"
            + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    }

    private func identity(_ path: String?, fallback: String = "short", app: ProcessAppInfo? = nil,
                          lookups: Counter? = nil) -> ProcessIdentity {
        ProcessIdentity.make(path: path, fallbackName: fallback) {
            lookups?.value += 1
            return app
        }
    }

    func testAppMainExecutableIsItsOwnGroupLeader() {
        let app = ProcessAppInfo(name: "Google Chrome", icon: nil, isRegular: true)
        let result = identity(chrome + "/Contents/MacOS/Google Chrome", app: app)
        XCTAssertEqual(result.name, "Google Chrome")
        XCTAssertEqual(result.groupBundlePath, chrome)
        XCTAssertEqual(result.ownBundlePath, chrome)
        XCTAssertEqual(result.app?.name, "Google Chrome")
    }

    func testNestedHelperAppIsGroupedUnderTheOutermostApp() {
        let helperApp = ProcessAppInfo(name: "Google Chrome Helper (Renderer)", icon: nil, isRegular: false)
        let result = identity(renderer, app: helperApp)
        XCTAssertEqual(result.name, "Google Chrome Helper (Renderer)")
        XCTAssertEqual(result.groupBundlePath, chrome)
        XCTAssertNotEqual(result.ownBundlePath, chrome)
    }

    func testNonMainExecutableInsideABundleIsGroupedWithoutAnAppLookup() {
        let lookups = Counter()
        let result = identity("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", lookups: lookups)
        XCTAssertEqual(result.groupBundlePath, "/Applications/Xcode.app")
        XCTAssertNil(result.ownBundlePath)
        XCTAssertNil(result.app)
        XCTAssertEqual(lookups.value, 0)
    }

    func testNestedRegularAppKeepsItsOwnRow() {
        let simulator = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        let app = ProcessAppInfo(name: "Simulator", icon: nil, isRegular: true)
        let result = identity(simulator + "/Contents/MacOS/Simulator", app: app)
        XCTAssertEqual(result.groupBundlePath, simulator)
        XCTAssertEqual(result.ownBundlePath, simulator)
    }

    func testStandaloneProcessUsesThePathBasename() {
        let lookups = Counter()
        let result = identity("/usr/libexec/some-daemon-with-a-long-name", lookups: lookups)
        XCTAssertEqual(result.name, "some-daemon-with-a-long-name")
        XCTAssertNil(result.groupBundlePath)
        XCTAssertEqual(lookups.value, 0)
    }

    func testMissingPathFallsBackToTheShortName() {
        let result = identity(nil, fallback: "kernel_task")
        XCTAssertEqual(result.name, "kernel_task")
        XCTAssertNil(result.groupBundlePath)
    }

    func testBundleHelpers() {
        XCTAssertEqual(ProcessIdentity.appBundles(in: renderer),
                       [chrome, chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/1.0/Helpers/"
                            + "Google Chrome Helper (Renderer).app"])
        XCTAssertEqual(ProcessIdentity.appBundles(in: "/Applications/Weird.app"), [],
                       "the executable itself is never a bundle")
        XCTAssertEqual(ProcessIdentity.displayName(ofBundle: chrome), "Google Chrome")
        XCTAssertEqual(ProcessIdentity.displayName(ofBundle: "/x/Odd.APP"), "Odd")
    }
}
