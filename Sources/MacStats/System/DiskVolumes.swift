import Foundation

/// How a volume is attached, for the Disk page's volume list.
enum DiskVolumeKind: Equatable {
    case `internal`
    case external
    case removable
    case network

    /// Network wins (a share is never "internal"), then removable media (SD cards,
    /// which macOS may report as internal readers), then anything not internal.
    /// Unknown flags count as internal, the common case for the startup disk.
    static func classify(isLocal: Bool?, isInternal: Bool?, isRemovable: Bool?) -> DiskVolumeKind {
        if isLocal == false { return .network }
        if isRemovable == true { return .removable }
        if isInternal == false { return .external }
        return .internal
    }
}

/// The resource values of one mounted volume, as read from `URLResourceValues`.
/// Kept separate from `DiskVolumeInfo` so the derivation is testable without a disk.
struct DiskVolumeValues: Equatable {
    var path: String
    var name: String?
    var totalCapacity: Int?
    /// Plain free space, without purgeable files.
    var availableCapacity: Int?
    /// Free space including purgeable files: the figure Finder and the card show.
    var availableForImportantUsage: Int64?
    var formatDescription: String?
    var isEncrypted: Bool?
    var isLocal: Bool?
    var isInternal: Bool?
    var isRemovable: Bool?
    var isRootFileSystem: Bool?
    var uuid: String?
    /// The device the volume is mounted from, e.g. "disk3s1s1" or "//server/share".
    var mountedFrom: String?

    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey,
        .volumeIsEncryptedKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsRootFileSystemKey, .volumeUUIDStringKey,
    ]

    init(path: String, name: String? = nil, totalCapacity: Int? = nil, availableCapacity: Int? = nil,
         availableForImportantUsage: Int64? = nil, formatDescription: String? = nil, isEncrypted: Bool? = nil,
         isLocal: Bool? = nil, isInternal: Bool? = nil, isRemovable: Bool? = nil, isRootFileSystem: Bool? = nil,
         uuid: String? = nil, mountedFrom: String? = nil) {
        self.path = path
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.formatDescription = formatDescription
        self.isEncrypted = isEncrypted
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isRootFileSystem = isRootFileSystem
        self.uuid = uuid
        self.mountedFrom = mountedFrom
    }

    /// `mountedFrom` comes from `statfs`: the resource key for it needs macOS 13.3.
    init(url: URL, values: URLResourceValues, mountedFrom: String?) {
        self.init(path: url.standardizedFileURL.path,
                  name: values.volumeLocalizedName ?? values.volumeName,
                  totalCapacity: values.volumeTotalCapacity,
                  availableCapacity: values.volumeAvailableCapacity,
                  availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
                  formatDescription: values.volumeLocalizedFormatDescription,
                  isEncrypted: values.volumeIsEncrypted,
                  isLocal: values.volumeIsLocal,
                  isInternal: values.volumeIsInternal,
                  isRemovable: values.volumeIsRemovable,
                  isRootFileSystem: values.volumeIsRootFileSystem,
                  uuid: values.volumeUUIDString,
                  mountedFrom: mountedFrom)
    }
}

/// One volume's capacity, split the way the Disk page shows it:
/// `usedBytes + purgeableBytes + availableBytes == totalBytes` when purgeable is known.
struct DiskVolumeInfo: Equatable, Identifiable {
    let path: String
    let name: String
    let kind: DiskVolumeKind
    let isStartup: Bool
    let totalBytes: UInt64
    /// Free space as Finder counts it (purgeable files included); the card's "free".
    let freeBytes: UInt64
    /// Plain free space; nil when the volume reports only one free figure.
    let availableBytes: UInt64?
    /// Space macOS can reclaim on demand (caches, local snapshots); nil when unknown.
    let purgeableBytes: UInt64?
    let formatDescription: String?
    let isEncrypted: Bool?
    /// BSD name of the device, e.g. "disk3s1s1"; nil for network volumes.
    let bsdName: String?

    var id: String { path }
    var usedBytes: UInt64 { totalBytes - freeBytes }
    var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }

    /// Nil for a volume without a capacity or free figure (an empty or unreadable
    /// mount), so it is left out rather than drawn as 0 of 0 or as full. Used and free
    /// come from `DiskMetrics.makeSample`, so the startup volume reads exactly as the card.
    init?(_ values: DiskVolumeValues) {
        guard let total = values.totalCapacity, total > 0,
              let free = values.availableForImportantUsage ?? values.availableCapacity.map(Int64.init),
              let sample = DiskMetrics.makeSample(total: Int64(total), available: free) else { return nil }
        let plain = values.availableCapacity.map { UInt64(max($0, 0)) }
        // Only one free figure (network shares often lack "important usage"): no
        // purgeable split, and that figure is the free space.
        let hasBothFigures = values.availableForImportantUsage != nil && plain != nil
        path = values.path
        name = values.name.flatMap { $0.isEmpty ? nil : $0 } ?? (values.path as NSString).lastPathComponent
        kind = DiskVolumeKind.classify(isLocal: values.isLocal, isInternal: values.isInternal,
                                       isRemovable: values.isRemovable)
        isStartup = values.isRootFileSystem == true || values.path == "/"
        totalBytes = sample.totalBytes
        freeBytes = sample.totalBytes - sample.usedBytes
        availableBytes = hasBothFigures ? min(plain ?? 0, freeBytes) : nil
        purgeableBytes = hasBothFigures ? freeBytes - min(plain ?? 0, freeBytes) : nil
        formatDescription = values.formatDescription.flatMap { $0.isEmpty ? nil : $0 }
        isEncrypted = values.isEncrypted
        bsdName = values.mountedFrom.flatMap(Self.bsdName(fromMountSource:))
    }

    /// "disk3s1s1" from "disk3s1s1" or "/dev/disk3s1s1"; nil for anything else
    /// (network shares, disk images mounted by path).
    static func bsdName(fromMountSource source: String) -> String? {
        let name = source.hasPrefix("/dev/") ? String(source.dropFirst(5)) : source
        return name.hasPrefix("disk") && !name.contains("/") ? name : nil
    }
}

/// Reads the mounted volumes. Building the list is pure (`volumes(from:)`); only
/// `mountedVolumes()` and `startupVolume()` touch the file system (about 20 ms of CPU
/// for all volumes on an Apple M5, release build), so
/// callers run them off the main thread).
enum DiskVolumes {
    /// The startup volume group's role volumes (Data, Preboot, VM, Update…) live
    /// here; the sealed system snapshot at "/" already stands for all of them.
    static let systemVolumesPrefix = "/System/Volumes/"

    /// Visible volumes, the startup volume first and once, then by name.
    static func volumes(from values: [DiskVolumeValues]) -> [DiskVolumeInfo] {
        var seenPaths = Set<String>()
        var seenUUIDs = Set<String>()
        var result: [DiskVolumeInfo] = []
        for value in values where !value.path.hasPrefix(systemVolumesPrefix) {
            guard let volume = DiskVolumeInfo(value), seenPaths.insert(volume.path).inserted else { continue }
            if let uuid = value.uuid, !uuid.isEmpty, !seenUUIDs.insert(uuid).inserted { continue }
            if volume.isStartup, result.contains(where: \.isStartup) { continue }
            result.append(volume)
        }
        return result.sorted { lhs, rhs in
            if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
            switch lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.path < rhs.path
            }
        }
    }

    static func mountedVolumes() -> [DiskVolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: DiskVolumeValues.keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return volumes(from: urls.compactMap(read))
    }

    static func startupVolume() -> DiskVolumeInfo? {
        read(URL(fileURLWithPath: "/")).flatMap(DiskVolumeInfo.init)
    }

    private static func read(_ url: URL) -> DiskVolumeValues? {
        // A fresh URL: URL caches resource values per instance.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: Set(DiskVolumeValues.keys)) else { return nil }
        return DiskVolumeValues(url: fresh, values: values, mountedFrom: mountSource(of: fresh.path))
    }

    /// The device a path's file system is mounted from, e.g. "/dev/disk3s1s1".
    private static func mountSource(of path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
