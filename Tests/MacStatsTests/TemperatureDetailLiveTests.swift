import XCTest
@testable import MacStats

/// The Temperature page's one live-hardware check. Lenient by design (VMs and CI
/// runners have no SMC sensors); it prints which mapped keys this Mac has and the
/// sampler's cost quoted in `TemperatureDetailModel`'s documentation.
final class TemperatureDetailLiveTests: XCTestCase {

    func testLiveReadAndSampleCost() {
        let chip = LiveSysctlReader().string("machdep.cpu.brand_string")
        let family = TemperatureChipFamily(chipName: chip)
        let sensors = family.map(TemperatureSensorCatalog.sensors(for:)) ?? []
        let source = LiveTemperatureSensorSource()

        let report = TemperatureSensorReader.read(sensors, from: source)
        for reading in report.readings {
            XCTAssertTrue(SMCService.isPlausibleTemperature(reading.celsius), reading.sensor.key)
        }
        if report.isMapped {
            let present = Set(report.readings.map(\.sensor.key))
            let missing = sensors.map(\.key).filter { !present.contains($0) }
            print("Temperature sensors on \(chip ?? "?"): \(present.count) of \(sensors.count) mapped keys read; "
                  + "not present or implausible: \(missing.joined(separator: " "))")
        } else {
            print("Temperature sensors on \(chip ?? "?"): not mapped; fallback \(report.readings.map(\.sensor.key))")
        }

        let runs = 50
        let start = FanDetailSamplerTests.processCPUNanoseconds()
        for _ in 0..<runs { _ = TemperatureSensorReader.read(sensors, from: source) }
        let perSample = Double(FanDetailSamplerTests.processCPUNanoseconds() - start) / Double(runs) / 1_000_000
        print(String(format: "TemperatureSensorReader cost: %.3f ms CPU per sample = %.4f %% of one core at 2 s",
                     perSample, perSample / 2_000 * 100))
        XCTAssertLessThan(perSample, 100, "a sample should be far cheaper than its interval")
    }
}
