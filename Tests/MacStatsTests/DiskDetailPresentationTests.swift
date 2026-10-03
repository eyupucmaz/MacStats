import XCTest
@testable import MacStats

/// The Disk page's text: headline, capacity rows, volume and process rows, activity
/// and drive details, in English and Turkish, and what is hidden when unknown.
final class DiskDetailPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US_POSIX")
    private let turkish = Locale(identifier: "tr_TR")

    private func snapshot(used: UInt64 = 300_000_000_000, total: UInt64 = 494_000_000_000) -> StatsSnapshot {
        StatsSnapshot(diskUsedBytes: used, diskTotalBytes: total)
    }

    private func volume(available: Int? = 80_000_000_000, important: Int64? = 90_000_000_000,
                        format: String? = "APFS", encrypted: Bool? = true) -> DiskVolumeInfo {
        DiskVolumeInfo(DiskVolumeValues(path: "/", name: "Macintosh HD", totalCapacity: 500_000_000_000,
                                        availableCapacity: available, availableForImportantUsage: important,
                                        formatDescription: format, isEncrypted: encrypted, isLocal: true,
                                        isInternal: true, isRemovable: false, isRootFileSystem: true))!
    }

    private func process(_ name: String, read: Double, write: Double, measured: Bool = true) -> ProcessUsage {
        ProcessUsage(id: name, pid: 1, pids: [1], name: name, icon: nil, cpuPercent: 0, cpuShareOfCapacity: 0,
                     memoryBytes: 0, diskReadBytesPerSecond: read, diskWriteBytesPerSecond: write,
                     isMeasured: measured)
    }

    // MARK: - Headline

    func testHeadlineMatchesTheCard() throws {
        try L10n.$language.withValue("en") {
            let headline = try XCTUnwrap(DiskDetailPresentation.headline(snapshot(), locale: english))
            XCTAssertEqual(headline.percentUsed, "61% used")
            XCTAssertEqual(headline.freeOfTotal, "194 GB free of 494 GB")
            XCTAssertEqual(headline.usedFraction, 300.0 / 494.0, accuracy: 1e-9)
            XCTAssertEqual(headline.accessibility, StatCardFactory.disk(snapshot(), locale: english).accessibility)
            // The card says the same.
            XCTAssertEqual(StatCardFactory.disk(snapshot(), locale: english).value, "61% used · 194 GB free")
        }
    }

    func testHeadlineInTurkish() throws {
        try L10n.$language.withValue("tr") {
            let headline = try XCTUnwrap(DiskDetailPresentation.headline(snapshot(), locale: turkish))
            XCTAssertEqual(headline.percentUsed, "%61 dolu")
            XCTAssertEqual(headline.freeOfTotal, "194 GB boş, toplam 494 GB")
        }
    }

    func testNoHeadlineWithoutACapacityReading() {
        XCTAssertNil(DiskDetailPresentation.headline(snapshot(used: 0, total: 0)))
    }

    // MARK: - Capacity

    func testCapacityRowsShowTheFullBreakdown() {
        L10n.$language.withValue("en") {
            let rows = DiskDetailPresentation.capacityRows(volume(), locale: english)
            XCTAssertEqual(rows.map(\.label), ["Volume name", "Used space", "Purgeable space", "Available space",
                                               "File system", "Encryption"])
            XCTAssertEqual(rows.map(\.value), ["Macintosh HD", "410 GB", "10 GB", "80 GB", "APFS", "Encrypted"])
            XCTAssertEqual(rows.map(\.part), [nil, .used, .purgeable, .available, nil, nil])
            XCTAssertEqual(rows[1].accessibility, "Used space, 410 gigabytes")
        }
    }

    func testUnknownCapacityFiguresAreHidden() {
        L10n.$language.withValue("en") {
            let rows = DiskDetailPresentation.capacityRows(volume(available: nil, format: nil, encrypted: nil),
                                                           locale: english)
            XCTAssertEqual(rows.map(\.label), ["Volume name", "Used space", "Available space"])
            XCTAssertEqual(rows[2].value, "90 GB")
        }
    }

    func testCapacityRowsInTurkish() {
        L10n.$language.withValue("tr") {
            let rows = DiskDetailPresentation.capacityRows(volume(encrypted: false), locale: turkish)
            XCTAssertEqual(rows.map(\.label), ["Birim adı", "Kullanılan alan", "Temizlenebilir alan",
                                               "Kullanılabilir alan", "Dosya sistemi", "Şifreleme"])
            XCTAssertEqual(rows.last?.value, "Şifreli değil")
        }
    }

    func testSegmentsCoverTheWholeBar() {
        let segments = DiskDetailPresentation.segments(volume())
        XCTAssertEqual(segments.used, 0.82, accuracy: 1e-9)
        XCTAssertEqual(segments.purgeable, 0.02, accuracy: 1e-9)
        XCTAssertEqual(segments.used + segments.purgeable + segments.available, 1, accuracy: 1e-9)
    }

    // MARK: - Volumes

    func testVolumeRowIsSpokenInFull() {
        L10n.$language.withValue("en") {
            XCTAssertEqual(DiskDetailPresentation.volumeAccessibility(volume(), locale: english),
                           "Macintosh HD, Internal, startup disk, 82 percent used, 90 gigabytes free of 500 gigabytes")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(DiskDetailPresentation.volumeAccessibility(volume(), locale: turkish),
                           "Macintosh HD, Dahili, başlangıç diski, yüzde 82 dolu, boş alan 90 gigabayt, toplam 500 gigabayt")
        }
    }

    func testEveryKindHasALabelAndAnIcon() {
        L10n.$language.withValue("en") {
            let kinds: [DiskVolumeKind] = [.internal, .external, .removable, .network]
            XCTAssertEqual(kinds.map(DiskDetailPresentation.kindLabel), ["Internal", "External", "Removable", "Network"])
            XCTAssertEqual(Set(kinds.map(DiskDetailPresentation.kindIcon)).count, kinds.count)
        }
    }

    // MARK: - Activity

    func testActivityRowsWaitForRatesButShowTotalsAtOnce() {
        L10n.$language.withValue("en") {
            let totals = DiskIOCounters(readBytes: 8_797_439_414_272, writeBytes: 3_787_083_821_056)
            let first = DiskDetailPresentation.activityRows(DiskActivityReport(totals: totals, rates: nil),
                                                            locale: english)
            XCTAssertEqual(first.map(\.label), ["Read since startup", "Written since startup"])
            XCTAssertEqual(first.map(\.value), ["8.8 TB", "3.8 TB"])

            let rates = DiskIORates(readBytesPerSecond: 0, writeBytesPerSecond: 0,
                                    readOperationsPerSecond: 1_250.4, writeOperationsPerSecond: 0)
            let later = DiskDetailPresentation.activityRows(DiskActivityReport(totals: totals, rates: rates),
                                                            locale: english)
            XCTAssertEqual(later.map(\.label), ["Read operations", "Write operations",
                                                "Read since startup", "Written since startup"])
            XCTAssertEqual(later[0].value, "1250/s")
            XCTAssertEqual(later[0].accessibility, "Read operations, 1250 per second")
            XCTAssertEqual(later[1].value, "0/s")
        }
    }

    func testOperationsInTurkish() {
        L10n.$language.withValue("tr") {
            let operations = DiskDetailPresentation.operations(42, locale: turkish)
            XCTAssertEqual(operations.text, "42/sn")
            XCTAssertEqual(operations.spoken, "saniyede 42")
        }
    }

    // MARK: - Processes

    func testTopProcessesLeaveOutIdleOnesAndStopAtFive() {
        let processes = [process("idle", read: 0, write: 0), process("new", read: 0, write: 0, measured: false)]
            + (1...7).map { process("p\($0)", read: Double($0) * 1_000, write: 0) }
        let report = ProcessReport(processes: processes, skippedCount: 0, coreCount: 8)
        XCTAssertEqual(DiskDetailPresentation.topProcesses(report).map(\.name), ["p7", "p6", "p5", "p4", "p3"])

        let quiet = ProcessReport(processes: [process("idle", read: 0, write: 0)], skippedCount: 0, coreCount: 8)
        XCTAssertTrue(DiskDetailPresentation.topProcesses(quiet).isEmpty)
    }

    func testProcessRowText() {
        let row = process("Safari", read: 1_200_000, write: 340_000)
        L10n.$language.withValue("en") {
            XCTAssertEqual(DiskDetailPresentation.processDetail(row, locale: english), "Read 1.2 MB/s · Write 340 KB/s")
            XCTAssertEqual(DiskDetailPresentation.processAccessibility(row, locale: english),
                           "Safari, reading 1.2 megabytes per second, writing 340 kilobytes per second")
        }
        L10n.$language.withValue("tr") {
            XCTAssertEqual(DiskDetailPresentation.processDetail(row, locale: turkish), "Okuma 1,2 MB/sn · Yazma 340 KB/sn")
            XCTAssertEqual(DiskDetailPresentation.processAccessibility(row, locale: turkish),
                           "Safari, okuma saniyede 1,2 megabayt, yazma saniyede 340 kilobayt")
        }
    }

    // MARK: - About

    func testDriveFromAppleSiliconRegistry() throws {
        let drive = try XCTUnwrap(DiskDriveInfo.make(
            device: ["Serial Number": "03c3a15c1e29a02e", "Medium Type": "Solid State",
                     "Product Name": "APPLE SSD AP0512Z", "Vendor Name": "", "Product Revision Level": "2973.120"],
            protocolInfo: ["Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal"]))
        XCTAssertEqual(drive, DiskDriveInfo(model: "APPLE SSD AP0512Z", interconnect: "Apple Fabric",
                                            isSolidState: true, firmware: "2973.120"))
        L10n.$language.withValue("en") {
            let rows = DiskDetailPresentation.aboutRows(drive)
            XCTAssertEqual(rows.map(\.label), ["Drive model", "Drive type", "Connection", "Firmware"])
            XCTAssertEqual(rows.map(\.value), ["APPLE SSD AP0512Z", "Solid-state drive", "Apple Fabric", "2973.120"])
        }
    }

    func testDriveModelJoinsVendorAndProductOnce() {
        XCTAssertEqual(DiskDriveInfo.make(device: ["Vendor Name": "Samsung", "Product Name": "Portable SSD T7"],
                                          protocolInfo: nil)?.model, "Samsung Portable SSD T7")
        XCTAssertEqual(DiskDriveInfo.make(device: ["Vendor Name": "WD", "Product Name": "WD Elements 25A2 "],
                                          protocolInfo: nil)?.model, "WD Elements 25A2")
        XCTAssertEqual(DiskDriveInfo.make(device: ["Vendor Name": "Generic"], protocolInfo: nil)?.model, "Generic")
    }

    func testUnknownDriveDetailsAreHidden() throws {
        XCTAssertNil(DiskDriveInfo.make(device: nil, protocolInfo: nil))
        XCTAssertNil(DiskDriveInfo.make(device: ["Vendor Name": " ", "Medium Type": "Other"], protocolInfo: [:]))
        let usb = try XCTUnwrap(DiskDriveInfo.make(device: nil, protocolInfo: ["Physical Interconnect": "USB"]))
        L10n.$language.withValue("en") {
            XCTAssertEqual(DiskDetailPresentation.aboutRows(usb).map(\.label), ["Connection"])
        }
        let rotational = try XCTUnwrap(DiskDriveInfo.make(device: ["Medium Type": "Rotational"], protocolInfo: nil))
        L10n.$language.withValue("tr") {
            XCTAssertEqual(DiskDetailPresentation.aboutRows(rotational).map(\.value), ["Sabit disk sürücüsü"])
        }
    }
}
