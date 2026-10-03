import XCTest
@testable import MacStats

/// Wording, grouping and hiding rules of the CPU page.
final class CPUDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US_POSIX")
    private let turkish = Locale(identifier: "tr_TR")

    private let superCores = CPUCoreGroup(kind: .perfLevel(0, name: "Super"), cores: 6..<10)
    private let efficiencyCores = CPUCoreGroup(kind: .perfLevel(1, name: "Efficiency"), cores: 0..<6)

    private func load(_ total: Double, system: Double = 0) -> CPUSample {
        CPUSample(total: total, user: total - system, system: system)
    }

    // MARK: - Headline

    func testHeadlineSplitsTheLatestReading() {
        XCTAssertEqual(CPUDetailPresentation.headline(total: 30, user: 20, system: 10),
                       CPUDetailPresentation.Headline(total: 30, user: 20, system: 10, idle: 70))
    }

    func testHeadlineIsHiddenUntilEveryValueIsMeasured() {
        XCTAssertNil(CPUDetailPresentation.headline(total: nil, user: nil, system: nil))
        XCTAssertNil(CPUDetailPresentation.headline(total: 30, user: nil, system: 10))
        XCTAssertNil(CPUDetailPresentation.headline(total: .nan, user: 20, system: 10))
    }

    func testHeadlineClampsIdleAtZero() {
        XCTAssertEqual(CPUDetailPresentation.headline(total: 100.2, user: 90, system: 10.2)?.idle, 0)
    }

    // MARK: - Cores

    func testCoreGroupsUsePerfLevelsWhenTheyCoverEveryCore() {
        let groups = [superCores, efficiencyCores]
        XCTAssertEqual(CPUDetailPresentation.coreGroups(groups, coreCount: 10), groups)
    }

    func testCoreGroupsFallBackToOneGroupWhenTheCountsDisagree() {
        XCTAssertEqual(CPUDetailPresentation.coreGroups([superCores, efficiencyCores], coreCount: 8),
                       [CPUCoreGroup(kind: .all, cores: 0..<8)])
        XCTAssertEqual(CPUDetailPresentation.coreGroups([], coreCount: 0), [])
    }

    func testGroupTitlesTranslateKnownPerfLevelNames() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(CPUDetailPresentation.title(of: superCores), "Super cores")
            XCTAssertEqual(CPUDetailPresentation.title(of: efficiencyCores), "Efficiency cores")
            XCTAssertEqual(CPUDetailPresentation.title(of: CPUCoreGroup(kind: .perfLevel(0, name: "Turbo"), cores: 0..<2)),
                           "Turbo cores")
            XCTAssertEqual(CPUDetailPresentation.title(of: CPUCoreGroup(kind: .perfLevel(0, name: nil), cores: 0..<2)),
                           "Performance cores")
            XCTAssertEqual(CPUDetailPresentation.title(of: CPUCoreGroup(kind: .all, cores: 0..<8)), "Cores")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(CPUDetailPresentation.title(of: CPUCoreGroup(kind: .perfLevel(0, name: "Performance"),
                                                                        cores: 0..<4)),
                           "Performans çekirdekleri")
            XCTAssertEqual(CPUDetailPresentation.title(of: efficiencyCores), "Verimlilik çekirdekleri")
        }
    }

    func testGroupAverageSkipsUnmeasuredCores() {
        let cores: [CPUSample?] = [load(10), load(30), nil]
        let group = CPUCoreGroup(kind: .all, cores: 0..<3)
        XCTAssertEqual(CPUDetailPresentation.average(of: group, in: cores), 20)
        XCTAssertNil(CPUDetailPresentation.average(of: group, in: [nil, nil, nil]))
        XCTAssertNil(CPUDetailPresentation.average(of: superCores, in: cores), "indices past the array are ignored")
    }

    func testSpokenGroupListsEveryCore() {
        let cores: [CPUSample?] = [load(10), nil]
        let group = CPUCoreGroup(kind: .perfLevel(1, name: "Efficiency"), cores: 0..<2)
        L10n.$language.withValue("en") {
            let spoken = CPUDetailPresentation.spokenGroup(group, cores: cores, locale: english)
            XCTAssertEqual(spoken.label, "Efficiency cores, average 10 percent")
            XCTAssertEqual(spoken.value, "Core 1, 10 percent; Core 2, Unavailable")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(CPUDetailPresentation.spokenCore(6, load: load(23.4), locale: turkish), "Çekirdek 7, yüzde 23")
        }
    }

    // MARK: - Load average

    func testLoadColumns() {
        let average = CPULoadAverage(one: 2.314, five: 1.5, fifteen: 0.98)
        L10n.$language.withValue("en") {
            let columns = CPUDetailPresentation.loadColumns(average, locale: english)
            XCTAssertEqual(columns.map(\.value), ["2.31", "1.50", "0.98"])
            XCTAssertEqual(columns.map(\.label), ["1 min", "5 min", "15 min"])
            XCTAssertEqual(columns[1].spokenLabel, "Load average over 5 minutes")
            XCTAssertEqual(CPUDetailPresentation.loadContext(cores: 10), "Out of 10 cores; higher means work is waiting.")
        }
        L10n.$language.withValue("tr") {
            let columns = CPUDetailPresentation.loadColumns(average, locale: turkish)
            XCTAssertEqual(columns[0].value, "2,31")
            XCTAssertEqual(columns[2].label, "15 dk")
        }
    }

    // MARK: - About

    func testUptimeFormats() {
        L10n.$language.withValue("en") {
            let days = CPUDetailPresentation.uptime(3 * 86_400 + 4 * 3_600 + 59)
            XCTAssertEqual(days?.text, "3 d 4 h")
            XCTAssertEqual(days?.spoken, "3 days, 4 hours")
            XCTAssertEqual(CPUDetailPresentation.uptime(86_400 + 3_600)?.spoken, "1 day, 1 hour")
            XCTAssertEqual(CPUDetailPresentation.uptime(4 * 3_600 + 12 * 60)?.text, "4 h 12 min")
            XCTAssertEqual(CPUDetailPresentation.uptime(60)?.spoken, "1 minute")
            XCTAssertEqual(CPUDetailPresentation.uptime(30)?.text, "0 min")
            XCTAssertNil(CPUDetailPresentation.uptime(-1), "a boot time in the future is hidden")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(CPUDetailPresentation.uptime(3 * 86_400 + 4 * 3_600)?.text, "3 g 4 sa")
            XCTAssertEqual(CPUDetailPresentation.uptime(4 * 3_600 + 12 * 60)?.spoken, "4 saat, 12 dakika")
        }
    }

    func testThermalStates() {
        typealias Level = CPUDetailPresentation.ThermalLevel
        XCTAssertEqual(Level(.nominal), .nominal)
        XCTAssertEqual(Level(.critical), .critical)
        L10n.$language.withValue("en") {
            XCTAssertEqual([Level.nominal, .fair, .serious, .critical].map(\.text),
                           ["Nominal", "Fair", "Serious", "Critical"])
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual([Level.nominal, .fair, .serious, .critical].map(\.text),
                           ["Normal", "Orta", "Yüksek", "Kritik"])
        }
    }

    // MARK: - Processes

    func testProcessValueUsesActivityMonitorPercent() {
        let usage = ProcessUsage(id: "pid:1", pid: 1, pids: [1], name: "claude", icon: nil,
                                 cpuPercent: 142.5, cpuShareOfCapacity: 14.25, memoryBytes: 0,
                                 diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, isMeasured: true)
        L10n.$language.withValue("en") {
            let value = CPUDetailPresentation.processValue(usage, locale: english)
            XCTAssertEqual(value.text, "142.5%")
            XCTAssertEqual(value.spoken, "claude, 142.5 percent")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(CPUDetailPresentation.processValue(usage, locale: turkish).text, "%142,5")
        }
    }
}
