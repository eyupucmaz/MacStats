import XCTest
@testable import MacStats

/// Chip facts, perf-level grouping and load average parsing for the CPU page, fed
/// with other Macs' `sysctl` values.
final class CPUDetailInfoTests: XCTestCase {

    private struct FakeSysctl: SysctlReading {
        var strings: [String: String] = [:]
        var ints: [String: Int] = [:]
        var boot: Date?

        func string(_ name: String) -> String? { strings[name] }
        func int(_ name: String) -> Int? { ints[name] }
        func bootTime() -> Date? { boot }
    }

    /// An M5: perflevel0 "Super" ×4, perflevel1 "Efficiency" ×6; CPUs 0–5 are E cores.
    private let m5 = FakeSysctl(strings: ["machdep.cpu.brand_string": "Apple M5",
                                          "hw.perflevel0.name": "Super",
                                          "hw.perflevel1.name": "Efficiency"],
                                ints: ["hw.logicalcpu": 10, "hw.nperflevels": 2,
                                       "hw.perflevel0.logicalcpu": 4, "hw.perflevel1.logicalcpu": 6],
                                boot: Date(timeIntervalSince1970: 1_788_905_895))

    func testAppleSiliconSplitsIntoPerfLevelsFastestFirst() {
        let info = CPUInfo.read(from: m5)
        XCTAssertEqual(info.chipName, "Apple M5")
        XCTAssertEqual(info.logicalCores, 10)
        XCTAssertEqual(info.bootTime, Date(timeIntervalSince1970: 1_788_905_895))
        XCTAssertEqual(info.groups, [
            CPUCoreGroup(kind: .perfLevel(0, name: "Super"), cores: 6..<10),
            CPUCoreGroup(kind: .perfLevel(1, name: "Efficiency"), cores: 0..<6),
        ])
    }

    func testM1ProLayout() {
        let groups = CPUInfo.groups(levels: [(8, "Performance"), (2, "Efficiency")], logicalCores: 10)
        XCTAssertEqual(groups.map(\.cores), [2..<10, 0..<2])
    }

    func testIntelIsOneGroup() {
        let intel = FakeSysctl(strings: ["machdep.cpu.brand_string": "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"],
                               ints: ["hw.logicalcpu": 16, "hw.nperflevels": 1, "hw.perflevel0.logicalcpu": 16])
        let info = CPUInfo.read(from: intel)
        XCTAssertEqual(info.groups, [CPUCoreGroup(kind: .all, cores: 0..<16)])
        XCTAssertNil(info.bootTime)
    }

    func testCountsThatDoNotAddUpFallBackToOneGroup() {
        XCTAssertEqual(CPUInfo.groups(levels: [(4, nil), (2, nil)], logicalCores: 10),
                       [CPUCoreGroup(kind: .all, cores: 0..<10)])
        XCTAssertEqual(CPUInfo.groups(levels: [(10, nil), (0, nil)], logicalCores: 10),
                       [CPUCoreGroup(kind: .all, cores: 0..<10)])
        XCTAssertEqual(CPUInfo.groups(levels: [], logicalCores: 0), [])
    }

    func testMissingChipNameIsHidden() {
        var noName = m5
        noName.strings["machdep.cpu.brand_string"] = nil
        XCTAssertNil(CPUInfo.read(from: noName).chipName)
    }

    func testLoadAverageNeedsAllThreeValues() {
        XCTAssertEqual(CPULoadAverage.make(values: [1.5, 2.25, 3], count: 3),
                       CPULoadAverage(one: 1.5, five: 2.25, fifteen: 3))
        XCTAssertNil(CPULoadAverage.make(values: [1.5, 2.25, 3], count: -1))
        XCTAssertNil(CPULoadAverage.make(values: [1.5, 2.25, 0], count: 2))
        XCTAssertNil(CPULoadAverage.make(values: [1.5, .nan, 3], count: 3))
    }
}
