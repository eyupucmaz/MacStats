import Foundation
import IOKit
import Metal

/// One accelerator's "PerformanceStatistics", reduced to what the GPU page shows.
/// The keys are private and differ by driver (Apple silicon, Intel, AMD), so every
/// field is optional and a key that is missing stays nil rather than becoming 0.
struct GPUStatistics: Equatable {
    /// The same figure the card shows for this GPU (`GPUMetrics.utilization`).
    var utilization: Double?
    /// Share of time the pixel (fragment) pipeline was busy, 0...100.
    var renderer: Double?
    /// Share of time the geometry (tiling) pipeline was busy, 0...100.
    var tiler: Double?
    /// System memory the GPU driver has in use (Apple silicon, Intel).
    var memoryInUse: UInt64?
    /// System memory the driver has allocated, in use or not.
    var memoryAllocated: UInt64?
    /// Dedicated video memory in use and in total (discrete GPUs whose driver reports it).
    var videoMemoryUsed: UInt64?
    var videoMemoryTotal: UInt64?

    init(utilization: Double? = nil, renderer: Double? = nil, tiler: Double? = nil,
         memoryInUse: UInt64? = nil, memoryAllocated: UInt64? = nil,
         videoMemoryUsed: UInt64? = nil, videoMemoryTotal: UInt64? = nil) {
        self.utilization = utilization
        self.renderer = renderer
        self.tiler = tiler
        self.memoryInUse = memoryInUse
        self.memoryAllocated = memoryAllocated
        self.videoMemoryUsed = videoMemoryUsed
        self.videoMemoryTotal = videoMemoryTotal
    }

    /// Parses the dictionary as IOKit returns it. Byte counts of 0 are left out: a
    /// running GPU never has nothing in use, so 0 means the driver does not track it
    /// (e.g. Apple silicon's "In use system memory (driver)").
    init(_ stats: [String: Any]) {
        func percent(_ key: String) -> Double? {
            guard let value = (stats[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }
        func bytes(_ key: String) -> UInt64? {
            guard let value = (stats[key] as? NSNumber)?.int64Value, value > 0 else { return nil }
            return UInt64(value)
        }
        self.init(utilization: GPUMetrics.utilization(from: stats),
                  renderer: percent("Renderer Utilization %"),
                  tiler: percent("Tiler Utilization %"),
                  memoryInUse: bytes("In use system memory"),
                  memoryAllocated: bytes("Alloc system memory"),
                  videoMemoryUsed: bytes("vramUsedBytes"))
        if let used = videoMemoryUsed, let free = bytes("vramFreeBytes") {
            videoMemoryTotal = used &+ free
        }
    }
}

/// What the IORegistry says about one IOAccelerator, before it is matched with Metal.
struct GPURegistryEntry {
    let registryID: UInt64
    var ioClass: String?
    var model: String?
    var coreCount: Int?
    var statistics: [String: Any]?
}

/// The Metal view of a GPU, matched to its accelerator by registry ID.
struct GPUMetalDevice: Equatable {
    let registryID: UInt64
    let name: String
}

/// One GPU as the page lists it.
struct GPUDevice: Equatable, Identifiable {
    let id: UInt64
    /// IORegistry `model`, e.g. "Apple M5" or "AMD Radeon Pro 5500M".
    var model: String?
    /// Apple silicon only (`gpu-core-count`).
    var coreCount: Int?
    var metalName: String?
    /// Apple silicon GPUs (the `AGX` driver family) share unified memory with the CPU.
    var isAppleSilicon = false
    var statistics: GPUStatistics?
}

/// Everything the GPU page shows below its headline and chart.
struct GPUDetailReport: Equatable {
    var gpus: [GPUDevice] = []

    /// The GPU whose renderer and tiler lines the chart draws: the first that reports
    /// either. Stable while the page is open, unlike "the busiest one".
    var chartGPU: GPUDevice? {
        gpus.first { $0.statistics?.renderer != nil || $0.statistics?.tiler != nil }
    }

    /// Matches accelerators with Metal devices by registry ID. Entries with nothing to
    /// show are dropped; a Metal device without a readable accelerator is still listed.
    static func make(entries: [GPURegistryEntry], metal: [GPUMetalDevice]) -> GPUDetailReport {
        let metalByID = Dictionary(metal.map { ($0.registryID, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UInt64>()
        var gpus: [GPUDevice] = []
        for entry in entries.sorted(by: { $0.registryID < $1.registryID }) where !seen.contains(entry.registryID) {
            let metalName = metalByID[entry.registryID]
            let statistics = entry.statistics.map(GPUStatistics.init)
            guard entry.model != nil || metalName != nil || statistics != nil else { continue }
            seen.insert(entry.registryID)
            let isAppleSilicon = entry.ioClass?.hasPrefix("AGX") == true
                || (entry.model ?? metalName)?.hasPrefix("Apple ") == true
            gpus.append(GPUDevice(id: entry.registryID, model: entry.model, coreCount: entry.coreCount,
                                  metalName: metalName, isAppleSilicon: isAppleSilicon, statistics: statistics))
        }
        for device in metal.sorted(by: { $0.registryID < $1.registryID }) where seen.insert(device.registryID).inserted {
            gpus.append(GPUDevice(id: device.registryID, metalName: device.name,
                                  isAppleSilicon: device.name.hasPrefix("Apple ")))
        }
        return GPUDetailReport(gpus: gpus)
    }
}

/// Reads every IOAccelerator: the same nodes `GPUMetrics.sample()` reads for the card.
enum GPURegistry {
    static func readEntries() -> [GPURegistryEntry] {
        guard let matching = IOServiceMatching("IOAccelerator") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var entries: [GPURegistryEntry] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // Apple silicon puts `model` on the accelerator; Intel and AMD on the PCI device above it.
            let model = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            entries.append(GPURegistryEntry(registryID: id,
                                            ioClass: property("IOClass") as? String,
                                            model: modelName(from: model),
                                            coreCount: coreCount(from: property("gpu-core-count")),
                                            statistics: property("PerformanceStatistics") as? [String: Any]))
        }
        return entries
    }

    /// `model` is a string on Apple silicon and NUL-terminated bytes on PCI devices.
    static func modelName(from value: Any?) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let data as Data: text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default: text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func coreCount(from value: Any?) -> Int? {
        guard let count = (value as? NSNumber)?.intValue, count > 0 else { return nil }
        return count
    }
}

extension GPUMetalDevice {
    /// Every GPU Metal knows about. Uses `MTLCopyAllDevices`, not
    /// `MTLCreateSystemDefaultDevice`: on Macs with automatic graphics switching the
    /// latter would wake the discrete GPU just to read its name.
    ///
    /// The first call in the process loads Metal's driver: about 28 ms and 1.6 MB of
    /// footprint on an Apple M5, measured once. Later calls are microseconds.
    static func readAll() -> [GPUMetalDevice] {
        MTLCopyAllDevices().map { GPUMetalDevice(registryID: $0.registryID, name: $0.name) }
    }
}
