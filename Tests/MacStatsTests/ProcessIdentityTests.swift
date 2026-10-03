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

    // MARK: - Unhelpful executable names (#25)

    private let claudeCode = "/Users/me/.local/share/claude/versions/2.1.288"

    func testVersionNamedExecutableTakesItsNameFromArgv0() {
        let result = ProcessIdentity.make(path: claudeCode, fallbackName: "2.1.288",
                                          lookupApp: { nil }, firstArgument: { "claude" })
        XCTAssertEqual(result.name, "claude")
        XCTAssertNil(result.groupBundlePath)
    }

    func testArgv0PathIsReducedToItsBasename() {
        let name = ProcessIdentity.readableName("2.1.288", path: claudeCode,
                                                firstArgument: { "/usr/local/bin/claude" })
        XCTAssertEqual(name, "claude")
    }

    func testWithoutAUsefulArgv0TheNearestMeaningfulFolderNamesIt() {
        // argv[0] missing, or itself a version: "versions" is generic, so "claude" wins.
        XCTAssertEqual(ProcessIdentity.readableName("2.1.288", path: claudeCode, firstArgument: { nil }), "claude")
        XCTAssertEqual(ProcessIdentity.readableName("2.1.288", path: claudeCode, firstArgument: { "2.1.288" }), "claude")
        XCTAssertEqual(ProcessIdentity.readableName("20.11.1", path: "/opt/tools/node/v20.11.1/bin/20.11.1",
                                                    firstArgument: { nil }), "node")
    }

    func testNothingBetterKeepsTheOriginalName() {
        XCTAssertEqual(ProcessIdentity.readableName("1.0", path: nil, firstArgument: { nil }), "1.0")
        XCTAssertEqual(ProcessIdentity.readableName("1.0", path: "/1.0", firstArgument: { "" }), "1.0")
    }

    func testHelpfulNamesNeverReadTheArguments() {
        let lookups = Counter()
        let result = ProcessIdentity.make(path: "/usr/libexec/7-zip", fallbackName: "short", lookupApp: { nil },
                                          firstArgument: { lookups.value += 1; return "other" })
        XCTAssertEqual(result.name, "7-zip")
        XCTAssertEqual(lookups.value, 0)
    }

    func testUnhelpfulNameRule() {
        for name in ["2.1.288", "v20.11.1", "1.4.0-beta.2", "1.0+build.7", "12345", "", "  "] {
            XCTAssertTrue(ProcessIdentity.isUnhelpfulName(name), name)
        }
        for name in ["claude", "node", "7-zip", "2to3", "python3.12", "v8", "Google Chrome", "1Password"] {
            XCTAssertFalse(ProcessIdentity.isUnhelpfulName(name), name)
        }
    }

    // MARK: - KERN_PROCARGS2

    /// argc, the executable path, NUL padding, argv, then the environment.
    private func procargs(argc: Int32, path: String, argv: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(path.utf8) + [UInt8](repeating: 0, count: padding)
        for argument in argv + ["HOME=/Users/me"] { bytes += Array(argument.utf8) + [0] }
        return bytes
    }

    func testProcargsParserReturnsArgv0() {
        let buffer = procargs(argc: 2, path: claudeCode, argv: ["claude", "--resume"])
        XCTAssertEqual(ProcessArguments.firstArgument(procargs: buffer), "claude")
    }

    func testProcargsParserRejectsMalformedBuffers() {
        XCTAssertNil(ProcessArguments.firstArgument(procargs: [UInt8]()))
        XCTAssertNil(ProcessArguments.firstArgument(procargs: [1, 0, 0]))
        XCTAssertNil(ProcessArguments.firstArgument(procargs: procargs(argc: 0, path: "/bin/x", argv: [])))
        // Truncated inside argv[0].
        let truncated = procargs(argc: 1, path: "/bin/x", argv: ["claude"]).prefix(4 + 6 + 3 + 3)
        XCTAssertNil(ProcessArguments.firstArgument(procargs: truncated))
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
