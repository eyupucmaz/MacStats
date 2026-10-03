import XCTest
@testable import MacStats

/// Volume capacity split, classification and list building for the Disk page,
/// from injected resource values. Nothing here reads a real volume.
final class DiskDetailVolumeTests: XCTestCase {

    /// Readings taken from a real 512 GB Apple-silicon startup volume.
    private func startupValues() -> DiskVolumeValues {
        DiskVolumeValues(path: "/", name: "Macintosh HD", totalCapacity: 494_332_366_848,
                         availableCapacity: 87_813_795_840, availableForImportantUsage: 91_198_895_531,
                         formatDescription: "APFS", isEncrypted: false, isLocal: true, isInternal: true,
                         isRemovable: false, isRootFileSystem: true, uuid: "AE574DCD",
                         mountedFrom: "/dev/disk3s1s1")
    }

    // MARK: - Capacity split

    func testStartupVolumeSplitsIntoUsedPurgeableAndAvailable() throws {
        let volume = try XCTUnwrap(DiskVolumeInfo(startupValues()))
        XCTAssertEqual(volume.freeBytes, 91_198_895_531)
        XCTAssertEqual(volume.availableBytes, 87_813_795_840)
        XCTAssertEqual(volume.purgeableBytes, 91_198_895_531 - 87_813_795_840)
        XCTAssertEqual(volume.usedBytes + (volume.purgeableBytes ?? 0) + (volume.availableBytes ?? 0),
                       volume.totalBytes)
        XCTAssertTrue(volume.isStartup)
        XCTAssertEqual(volume.kind, .internal)
        XCTAssertEqual(volume.bsdName, "disk3s1s1")
        XCTAssertEqual(volume.formatDescription, "APFS")
        XCTAssertEqual(volume.isEncrypted, false)
    }

    /// The headline must match the card, which uses `DiskMetrics.makeSample`.
    func testUsedAndFreeMatchTheCardsReading() throws {
        let values = startupValues()
        let volume = try XCTUnwrap(DiskVolumeInfo(values))
        let card = try XCTUnwrap(DiskMetrics.makeSample(total: Int64(values.totalCapacity!),
                                                        available: values.availableForImportantUsage!))
        XCTAssertEqual(volume.usedBytes, card.usedBytes)
        XCTAssertEqual(volume.totalBytes, card.totalBytes)
    }

    func testPurgeableIsNeverNegative() throws {
        var values = startupValues()
        values.availableCapacity = 95_000_000_000   // more than "important usage"
        let volume = try XCTUnwrap(DiskVolumeInfo(values))
        XCTAssertEqual(volume.purgeableBytes, 0)
        XCTAssertEqual(volume.availableBytes, volume.freeBytes)
    }

    func testOneFreeFigureGivesNoPurgeableSplit() throws {
        let share = DiskVolumeValues(path: "/Volumes/Share", name: "Share", totalCapacity: 1_000,
                                     availableCapacity: 400, isLocal: false)
        let volume = try XCTUnwrap(DiskVolumeInfo(share))
        XCTAssertEqual(volume.freeBytes, 400)
        XCTAssertEqual(volume.usedBytes, 600)
        XCTAssertNil(volume.purgeableBytes)
        XCTAssertNil(volume.availableBytes)
        XCTAssertEqual(volume.kind, .network)
        XCTAssertNil(volume.bsdName)
    }

    func testVolumesWithoutCapacityOrFreeSpaceAreLeftOut() {
        XCTAssertNil(DiskVolumeInfo(DiskVolumeValues(path: "/Volumes/A", availableCapacity: 1)))
        XCTAssertNil(DiskVolumeInfo(DiskVolumeValues(path: "/Volumes/A", totalCapacity: 0, availableCapacity: 0)))
        // A capacity with no free figure would read as 100 % full: hidden instead.
        XCTAssertNil(DiskVolumeInfo(DiskVolumeValues(path: "/Volumes/A", totalCapacity: 1_000)))
    }

    func testFreeSpaceIsClampedToTheVolume() throws {
        let negative = try XCTUnwrap(DiskVolumeInfo(DiskVolumeValues(path: "/Volumes/A", totalCapacity: 1_000,
                                                                     availableForImportantUsage: -5)))
        XCTAssertEqual(negative.freeBytes, 0)
        XCTAssertEqual(negative.usedFraction, 1)
        let tooLarge = try XCTUnwrap(DiskVolumeInfo(DiskVolumeValues(path: "/Volumes/A", totalCapacity: 1_000,
                                                                     availableCapacity: 5_000,
                                                                     availableForImportantUsage: 5_000)))
        XCTAssertEqual(tooLarge.usedBytes, 0)
        XCTAssertEqual(tooLarge.purgeableBytes, 0)
    }

    func testNameFallsBackToTheMountPoint() throws {
        let volume = try XCTUnwrap(DiskVolumeInfo(DiskVolumeValues(path: "/Volumes/Backup", name: "",
                                                                   totalCapacity: 10, availableCapacity: 5)))
        XCTAssertEqual(volume.name, "Backup")
    }

    // MARK: - Classification

    func testKindClassification() {
        XCTAssertEqual(DiskVolumeKind.classify(isLocal: true, isInternal: true, isRemovable: false), .internal)
        XCTAssertEqual(DiskVolumeKind.classify(isLocal: true, isInternal: false, isRemovable: false), .external)
        // SD cards sit in an internal reader but are removable media.
        XCTAssertEqual(DiskVolumeKind.classify(isLocal: true, isInternal: true, isRemovable: true), .removable)
        XCTAssertEqual(DiskVolumeKind.classify(isLocal: false, isInternal: nil, isRemovable: nil), .network)
        XCTAssertEqual(DiskVolumeKind.classify(isLocal: nil, isInternal: nil, isRemovable: nil), .internal)
    }

    func testBSDNameFromMountSource() {
        XCTAssertEqual(DiskVolumeInfo.bsdName(fromMountSource: "/dev/disk3s1s1"), "disk3s1s1")
        XCTAssertEqual(DiskVolumeInfo.bsdName(fromMountSource: "disk5s2"), "disk5s2")
        XCTAssertNil(DiskVolumeInfo.bsdName(fromMountSource: "//user@server/share"))
        XCTAssertNil(DiskVolumeInfo.bsdName(fromMountSource: "map auto_home"))
    }

    // MARK: - List

    func testListShowsTheStartupVolumeOnceAndFirst() {
        func volume(_ path: String, _ name: String, uuid: String? = nil, root: Bool = false) -> DiskVolumeValues {
            DiskVolumeValues(path: path, name: name, totalCapacity: 1_000, availableCapacity: 500,
                             isRootFileSystem: root, uuid: uuid)
        }
        let list = DiskVolumes.volumes(from: [
            volume("/Volumes/Photos 10", "Photos 10"),
            volume("/System/Volumes/Data", "Macintosh HD - Data", uuid: "DATA"),
            volume("/System/Volumes/VM", "VM"),
            volume("/", "Macintosh HD", uuid: "ROOT", root: true),
            volume("/Volumes/photos 2", "photos 2"),
            volume("/Volumes/Backup", "Backup", uuid: "B"),
            volume("/Volumes/Backup 1", "Backup", uuid: "B"),      // same volume mounted twice
            volume("/Volumes/Backup", "Backup"),                    // same path listed twice
            volume("/Volumes/Empty", "Empty").with { $0.totalCapacity = 0 },
        ])
        XCTAssertEqual(list.map(\.path), ["/", "/Volumes/Backup", "/Volumes/photos 2", "/Volumes/Photos 10"])
        XCTAssertEqual(list.filter(\.isStartup).count, 1)
    }
}

private extension DiskVolumeValues {
    func with(_ change: (inout DiskVolumeValues) -> Void) -> DiskVolumeValues {
        var copy = self
        change(&copy)
        return copy
    }
}
