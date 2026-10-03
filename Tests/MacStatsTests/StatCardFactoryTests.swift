import XCTest
@testable import MacStats

/// Card values and VoiceOver strings, pinned to a locale so they hold on any machine.
final class StatCardFactoryTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let german = Locale(identifier: "de_DE")

    private func snapshot() -> StatsSnapshot {
        StatsSnapshot(
            cpuUsage: 23.45,
            gpuUsage: 15.2,
            isGPUAvailable: true,
            memoryUsed: 8_804_682_138,       // ~8.2 GiB
            memoryTotal: 17_179_869_184,     // 16 GiB
            diskUsedBytes: 300_000_000_000,  // 300 GB
            diskTotalBytes: 494_000_000_000, // 494 GB
            networkDownBytes: 1_200_000,
            networkUpBytes: 340_000,
            batteryLevel: 87,
            batteryState: "Discharging",
            fanRPM: 2502,
            isFanAvailable: true,
            temperature: 53.44,
            isTemperatureAvailable: true
        )
    }

    // MARK: - Values

    func testPercentagesShowOneDecimal() {
        XCTAssertEqual(StatCardFactory.cpu(snapshot(), locale: posix).value, "23.5%")
        XCTAssertEqual(StatCardFactory.gpu(snapshot(), locale: posix).value, "15.2%")
    }

    func testMemoryUsesBinaryGigabytes() {
        let card = StatCardFactory.memory(snapshot(), locale: posix)
        XCTAssertEqual(card.value, "8.2/16 GB")
        XCTAssertEqual(card.accessibility, "Memory 8.2 of 16 gigabytes used")
    }

    func testDiskKeepsPercentAndFreeSpaceInDecimalUnits() {
        let card = StatCardFactory.disk(snapshot(), locale: posix)
        XCTAssertEqual(card.value, "61% used · 194 GB free")
        XCTAssertEqual(card.accessibility, "Disk 61 percent full, 194 gigabytes free of 494 gigabytes")
    }

    func testNetworkRatesCarryPerSecond() {
        let card = StatCardFactory.network(snapshot(), locale: posix)
        XCTAssertEqual(card.value, "↓1.2 MB/s  ↑340 KB/s")
        XCTAssertEqual(card.accessibility,
                       "Network down 1.2 megabytes per second, up 340 kilobytes per second")
    }

    func testIdleNetworkIsNotBlank() {
        var s = snapshot()
        s.networkDownBytes = 0
        s.networkUpBytes = 0
        XCTAssertEqual(StatCardFactory.network(s, locale: posix).value, "↓0 B/s  ↑0 B/s")
    }

    func testFanAndTemperature() {
        XCTAssertEqual(StatCardFactory.fan(snapshot()).value, "2502 RPM")
        let temp = StatCardFactory.temperature(snapshot(), locale: posix)
        XCTAssertEqual(temp.value, "53.4°C")
        XCTAssertEqual(temp.accessibility, "Temperature 53.4 degrees Celsius")
    }

    func testBattery() {
        let card = StatCardFactory.battery(snapshot())
        XCTAssertEqual(card.value, "87%")
        XCTAssertEqual(card.icon, "battery.100")
        XCTAssertEqual(card.accessibility, "Battery 87 percent, Discharging")
    }

    func testDecimalsFollowTheLocale() {
        XCTAssertEqual(StatCardFactory.cpu(snapshot(), locale: german).value, "23,5%")
        XCTAssertEqual(StatCardFactory.memory(snapshot(), locale: german).value, "8,2/16 GB")
        XCTAssertEqual(StatCardFactory.network(snapshot(), locale: german).value, "↓1,2 MB/s  ↑340 KB/s")
        XCTAssertEqual(StatCardFactory.temperature(snapshot(), locale: german).accessibility,
                       "Temperature 53,4 degrees Celsius")
    }

    // MARK: - Unavailable readings

    func testUnavailableReadingsShowADash() {
        let s = StatsSnapshot()
        for card in [StatCardFactory.gpu(s, locale: posix), StatCardFactory.memory(s, locale: posix),
                     StatCardFactory.battery(s), StatCardFactory.disk(s, locale: posix),
                     StatCardFactory.fan(s), StatCardFactory.temperature(s, locale: posix)] {
            XCTAssertEqual(card.value, "—", card.id)
            XCTAssertTrue(card.accessibility.hasSuffix("not available"), "\(card.id): \(card.accessibility)")
        }
    }

    // MARK: - Battery icon

    func testBatteryIcon() {
        XCTAssertEqual(StatCardFactory.batteryIcon(state: "Charging", level: 10), "battery.100.bolt")
        XCTAssertEqual(StatCardFactory.batteryIcon(state: "Full", level: 100), "battery.100")
        XCTAssertEqual(StatCardFactory.batteryIcon(state: "Discharging", level: 76), "battery.100")
        XCTAssertEqual(StatCardFactory.batteryIcon(state: "Discharging", level: 75), "battery.50")
        XCTAssertEqual(StatCardFactory.batteryIcon(state: "Discharging", level: 37), "battery.25")
        XCTAssertEqual(StatCardFactory.batteryIcon(state: "AC Power", level: 0), "battery.0")
    }

    // MARK: - Visibility

    func testCardsFollowSettingsInDisplayOrder() {
        let suite = "StatCardFactoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(StatCardFactory.cards(snapshot(), settings: settings, locale: posix).map(\.id),
                       ["cpu", "gpu", "ram", "battery", "disk", "network", "fan", "temp"])

        settings.showGPU = false
        settings.showFan = false
        XCTAssertEqual(StatCardFactory.cards(snapshot(), settings: settings, locale: posix).map(\.id),
                       ["cpu", "ram", "battery", "disk", "network", "temp"])
    }
}

/// One formatter per kind of quantity.
final class FormattersTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    func testRatesStepUpInsteadOfShowingFourDigits() {
        XCTAssertEqual(ByteRate.short(999, locale: posix), "999 B/s")
        XCTAssertEqual(ByteRate.short(1_500, locale: posix), "1.5 KB/s")
        XCTAssertEqual(ByteRate.short(812_000, locale: posix), "812 KB/s")
        XCTAssertEqual(ByteRate.short(999_960, locale: posix), "1.0 MB/s")
        XCTAssertEqual(ByteRate.short(12_300_000, locale: posix), "12 MB/s")
        XCTAssertEqual(ByteRate.short(2_500_000_000, locale: posix), "2.5 GB/s")
    }

    func testRatesNeverGoNegativeOrNaN() {
        XCTAssertEqual(ByteRate.short(-5, locale: posix), "0 B/s")
        XCTAssertEqual(ByteRate.short(.nan, locale: posix), "0 B/s")
    }

    func testCompactRateDropsSpaceAndPerSecond() {
        XCTAssertEqual(ByteRate.compact(340_000, locale: posix), "340K")
        XCTAssertEqual(ByteRate.compact(0, locale: posix), "0B")
    }

    func testSpokenForms() {
        XCTAssertEqual(ByteRate.spoken(1_200_000, locale: posix), "1.2 megabytes per second")
        XCTAssertEqual(DiskSize.spoken(1_200_000_000_000, locale: posix), "1.2 terabytes")
    }

    func testMemoryDropsTheDecimalAboveOneHundredGigabytes() {
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(MemorySize.usedOfTotal(150 * gib, 192 * gib, locale: posix), "150/192 GB")
        XCTAssertEqual(MemorySize.compact(gib / 2, locale: posix), "0.5G")
    }
}
