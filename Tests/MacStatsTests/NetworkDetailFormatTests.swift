import XCTest
@testable import MacStats

/// The Network page's text in English and Turkish.
final class NetworkDetailFormatTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let turkish = Locale(identifier: "tr_TR")

    func testBitRates() {
        XCTAssertEqual(NetworkDetailFormat.bitRate(1_000_000_000, locale: english), "1 Gb/s")
        XCTAssertEqual(NetworkDetailFormat.bitRate(2_500_000_000, locale: english), "2.5 Gb/s")
        XCTAssertEqual(NetworkDetailFormat.bitRate(10_000_000_000, locale: english), "10 Gb/s")
        XCTAssertEqual(NetworkDetailFormat.bitRate(100_000_000, locale: english), "100 Mb/s")
        XCTAssertEqual(NetworkDetailFormat.bitRate(866_700_000, locale: english), "867 Mb/s")
        XCTAssertEqual(NetworkDetailFormat.bitRate(5_500_000, locale: english), "5.5 Mb/s")
        XCTAssertEqual(NetworkDetailFormat.bitRate(999_990_000, locale: english), "1 Gb/s",
                       "steps up once rounding reaches the next unit")
        XCTAssertEqual(NetworkDetailFormat.bitRate(64_000, locale: english), "64 kb/s")
        XCTAssertEqual(NetworkDetailFormat.spokenBitRate(1_000_000_000, locale: english), "1 gigabits per second")
    }

    func testWiFiValues() {
        XCTAssertEqual(NetworkDetailFormat.dBm(-62), "-62 dBm")
        XCTAssertEqual(NetworkDetailFormat.spokenDBm(-62), "-62 decibel-milliwatts")
        XCTAssertEqual(NetworkDetailFormat.channel(36, band: .ghz5), "36 (5 GHz)")
        XCTAssertEqual(NetworkDetailFormat.channel(6, band: .ghz2_4), "6 (2.4 GHz)")
        XCTAssertEqual(NetworkDetailFormat.channel(37, band: nil), "37")
    }

    func testPairs() {
        let totals = NetworkDetailFormat.totals(.init(inputBytes: 2_100_000_000, outputBytes: 310_000_000),
                                                title: "Since boot", locale: english)
        XCTAssertEqual(totals, .init(down: "↓2.1 GB", up: "↑310 MB",
                                     spoken: "Since boot, download 2.1 gigabytes, upload 310 megabytes"))
        XCTAssertNil(NetworkDetailFormat.totals(nil, title: "Since boot", locale: english))

        let rates = NetworkDetailFormat.rates(down: 1_200_000, up: 80_000, title: "Now", locale: english)
        XCTAssertEqual(rates.down, "↓1.2 MB/s")
        XCTAssertEqual(rates.up, "↑80 KB/s")
        XCTAssertEqual(rates.spoken, "Now, download 1.2 megabytes per second, upload 80 kilobytes per second")

        let waiting = NetworkDetailFormat.rates(down: nil, up: 5, title: "Now", locale: english)
        XCTAssertEqual(waiting.down, "↓—", "no invented zero before the first interval")
    }

    func testInterfaceNames() {
        let wifi = NetworkInterfaceDetail(name: "en0", kind: .wifi, isPrimary: true)
        XCTAssertEqual(NetworkDetailFormat.spokenInterface(wifi), "Wi-Fi, en0, primary")
        let other = NetworkInterfaceDetail(name: "en7", kind: .other, isPrimary: false)
        XCTAssertEqual(NetworkDetailFormat.spokenInterface(other), "Other, en7")
    }

    func testRendersInTurkish() {
        L10n.$language.withValue("tr") {
            XCTAssertEqual(NetworkDetailFormat.bitRate(2_500_000_000, locale: turkish), "2,5 Gb/sn")
            XCTAssertEqual(NetworkDetailFormat.spokenBitRate(100_000_000, locale: turkish), "saniyede 100 megabit")
            XCTAssertEqual(NetworkDetailFormat.channel(6, band: .ghz2_4), "6 (2,4 GHz)")
            XCTAssertEqual(NetworkDetailFormat.spokenDBm(-70), "-70 desibel-miliwatt")
            XCTAssertEqual(NetworkDetailFormat.kind(.other), "Diğer")
            let totals = NetworkDetailFormat.totals(.init(inputBytes: 2_100_000_000, outputBytes: 310_000_000),
                                                    title: L10n.string("Since boot"), locale: turkish)
            XCTAssertEqual(totals?.down, "↓2,1 GB")
            XCTAssertEqual(totals?.spoken,
                           "Sistem açılışından beri, indirme 2,1 gigabayt, yükleme 310 megabayt")
            let wifi = NetworkInterfaceDetail(name: "en0", kind: .wifi, isPrimary: true)
            XCTAssertEqual(NetworkDetailFormat.spokenInterface(wifi), "Wi-Fi, en0, birincil")
        }
    }
}
