import Foundation
import XCTest
@testable import MacStats

/// The string tables are complete, consistent, and actually used: every key has
/// an English and a Turkish value with matching format specifiers, and every
/// `L10n.string("…")` in the sources has a key.
final class LocalizationTests: XCTestCase {
    private let turkish = Locale(identifier: "tr_TR")

    private func table(_ language: String) throws -> [String: String] {
        let resources = try XCTUnwrap(L10n.resources, "SwiftPM resource bundle not found")
        let url = try XCTUnwrap(resources.url(forResource: "Localizable", withExtension: "strings",
                                              subdirectory: nil, localization: language),
                                "no Localizable.strings for \(language)")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "unreadable table for \(language)")
    }

    func testResourceBundleShipsEnglishAndTurkish() {
        XCTAssertEqual(L10n.availableLanguages, ["en", "tr"])
        XCTAssertEqual(L10n.developmentLanguage, "en")
    }

    func testEveryKeyHasAnEnglishAndATurkishValue() throws {
        let english = try table("en")
        let turkish = try table("tr")

        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(turkish.keys), "en.lproj and tr.lproj must hold the same keys")
        for (key, value) in english {
            XCTAssertEqual(value, key, "the English value is the key itself")
        }
        for (key, value) in turkish {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty Turkish value for \(key)")
        }
    }

    /// A translation that drops, adds or retypes an argument would crash or
    /// print garbage when formatted.
    func testTranslationsKeepTheFormatSpecifiers() throws {
        let english = try table("en")
        let turkish = try table("tr")
        for (key, value) in turkish {
            XCTAssertEqual(Self.specifiers(value), Self.specifiers(english[key] ?? ""), "specifiers differ for \(key)")
        }
    }

    func testEverySourceStringHasATableEntry() throws {
        let keys = Set(try table("en").keys.map(Self.normalizedKey))
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacStats")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            for literal in Self.l10nLiterals(in: try String(contentsOf: file, encoding: .utf8)) {
                checked += 1
                XCTAssertTrue(keys.contains(literal), "\(file.lastPathComponent): no table entry for \"\(literal)\"")
            }
        }
        XCTAssertGreaterThan(checked, 100, "the source scan found too few strings to be working")
    }

    // MARK: - Rendering

    func testCardsRenderInTurkish() {
        let s = snapshot()
        L10n.$language.withValue("tr") {
            let cpu = StatCardFactory.cpu(s, locale: turkish)
            XCTAssertEqual(cpu.value, "%23,5")
            XCTAssertEqual(cpu.accessibility, "CPU yüzde 23,5")

            let disk = StatCardFactory.disk(s, locale: turkish)
            XCTAssertEqual(disk.value, "%61 dolu · 194 GB boş")
            XCTAssertEqual(disk.accessibility, "Disk yüzde 61 dolu, boş alan 194 gigabayt, toplam 494 gigabayt")

            let memory = StatCardFactory.memory(s, locale: turkish)
            XCTAssertEqual(memory.accessibility, "Bellek, 16 gigabaytın 8,2 gigabaytı kullanılıyor")

            let network = StatCardFactory.network(s, locale: turkish)
            XCTAssertEqual(network.value, "↓1,2 MB/sn  ↑340 KB/sn")
            XCTAssertEqual(network.accessibility, "Ağ indirme saniyede 1,2 megabayt, yükleme saniyede 340 kilobayt")

            let battery = StatCardFactory.battery(s)
            XCTAssertEqual(battery.title, "Pil")
            XCTAssertEqual(battery.value, "%87")
            XCTAssertEqual(battery.accessibility, "Pil yüzde 87, pilden çalışıyor")

            XCTAssertEqual(StatCardFactory.fan(s).value, "2502 dev/dk")
            XCTAssertEqual(StatCardFactory.temperature(s, locale: turkish).accessibility, "Sıcaklık 53,4 santigrat derece")

            var missing = s
            missing.isGPUAvailable = false
            XCTAssertEqual(StatCardFactory.gpu(missing, locale: turkish).accessibility, "GPU kullanım bilgisi yok")
        }
    }

    func testMenuBarKeepsItsLabelsAndLocalizesThePercentSign() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(MenuBarRenderer.title([.cpu, .disk, .temp], snapshot(), locale: turkish),
                           "CPU %23  DSK %61  TMP 53°C")
            XCTAssertEqual(MenuBarMetric.ram.settingsTitle, "Bellek Kullanımı")
        }
    }

    func testEnglishIsUnchangedByTheTables() {
        L10n.$language.withValue("en") {
            let cpu = StatCardFactory.cpu(snapshot(), locale: Locale(identifier: "en_US_POSIX"))
            XCTAssertEqual(cpu.value, "23.5%")
            XCTAssertEqual(cpu.accessibility, "CPU 23.5 percent")
            XCTAssertEqual(SettingsView.intervalLabel(5), "5s")
        }
    }

    func testSettingsAndAudioLabelsRenderInTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(SettingsView.intervalLabel(30), "30 sn")
            XCTAssertEqual(MetricPlacement.menuBar.accessibilityLabel(for: .fan), "Fan Hızı, Menü çubuğu")
            XCTAssertEqual(AudioTabPresentation.volumeValue(level: 0.5, muted: true), "Sessize alındı, yüzde 50")
            XCTAssertEqual(AudioTabPresentation.muteLabel(for: "Safari"), "Safari sesini kapat")
            XCTAssertEqual(LaunchAtLogin.Failure.system("Hata").errorDescription,
                           "Oturum açılışında başlatma ayarı değiştirilemedi: Hata")
        }
    }

    func testAudioErrorsRenderInTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(AudioControlError.osStatus(-50).message, "macOS bu ses ayarını değiştiremedi (hata -50).")
            XCTAssertEqual(AudioControlError.deviceUnavailable.message, "Şu anda kullanılabilir bir çıkış aygıtı yok.")
            XCTAssertEqual(AppMixerService.outputChangedMessage,
                           "Çıkış aygıtı değiştiği için Uygulama Mikseri durdu. Yeni aygıtta karıştırmak için mikseri yeniden açın.")
        }
    }

    @MainActor
    func testAppMixerReportsPermissionDenialInTurkish() async {
        let service = AppMixerService(platform: DeniedAppMixerPlatform())
        await L10n.$language.withValue("tr") {
            await service.enable()
        }
        XCTAssertEqual(service.statusMessage, "MacStats'in uygulama sesini yakalama izni yok.")
    }

    // MARK: - Helpers

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

    /// Argument types in order of position, e.g. `["@", "lld"]`; `%%` is not an argument.
    static func specifiers(_ format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(@|lld|llu|ld|d)|%%")
        var arguments: [(position: Int, type: String)] = []
        for match in pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            guard let typeRange = Range(match.range(at: 2), in: format) else { continue }
            let position = Range(match.range(at: 1), in: format).flatMap { Int(format[$0]) } ?? arguments.count + 1
            arguments.append((position, String(format[typeRange])))
        }
        return arguments.sorted { $0.position < $1.position }.map(\.type)
    }

    /// A key with every argument replaced by `§` and `%%` unescaped: the form
    /// `l10nLiterals(in:)` reads from Swift source.
    static func normalizedKey(_ key: String) -> String {
        key.replacingOccurrences(of: "%(?:\\d+\\$)?(?:@|lld|llu|ld|d)", with: "§", options: .regularExpression)
            .replacingOccurrences(of: "%%", with: "%")
    }

    /// The literal of every `L10n.string("…")` call, with each interpolation
    /// `\(…)` (parentheses balanced) replaced by `§`.
    static func l10nLiterals(in source: String) -> [String] {
        let marker = "L10n.string(\""
        var literals: [String] = []
        var rest = source[...]
        while let start = rest.range(of: marker) {
            var index = start.upperBound
            var literal = ""
            while index < rest.endIndex, rest[index] != "\"" {
                let next = rest.index(after: index)
                if rest[index] == "\\", next < rest.endIndex, rest[next] == "(" {
                    var depth = 0
                    index = next
                    repeat {
                        if rest[index] == "(" { depth += 1 }
                        if rest[index] == ")" { depth -= 1 }
                        index = rest.index(after: index)
                    } while depth > 0 && index < rest.endIndex
                    literal += "§"
                } else if rest[index] == "\\", next < rest.endIndex {
                    literal.append(rest[next])
                    index = rest.index(after: next)
                } else {
                    literal.append(rest[index])
                    index = next
                }
            }
            literals.append(literal)
            rest = rest[index...]
        }
        return literals
    }
}

/// Denies capture permission without prompting, so `enable()` stops at once.
private final class DeniedAppMixerPlatform: AppMixerPlatform, @unchecked Sendable {
    let capability = AppMixerCapability.available
    let permission = AppMixerPermission.denied
    var onEvent: (@MainActor (AppMixerEvent) -> Void)?
    func requestPermission() async -> AppMixerPermission { .denied }
    func start(retaining: [AppMixerProcess]) async throws -> [AppMixerProcess] { [] }
    func stop() {}
    func apply(_ process: AppMixerProcess) {}
}
