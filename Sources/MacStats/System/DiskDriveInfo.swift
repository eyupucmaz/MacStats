import Foundation
import IOKit

/// The drive behind a volume, from the IOKit block storage device's
/// "Device Characteristics" and "Protocol Characteristics". Every field is optional:
/// drives report different subsets, and missing ones are hidden on the page.
/// No SMART data (out of scope) and no serial number (not needed to act on anything).
struct DiskDriveInfo: Equatable {
    /// e.g. "APPLE SSD AP0512Z", or vendor and product of an external drive.
    var model: String?
    /// e.g. "Apple Fabric", "PCI-Express", "USB", "SATA", "Thunderbolt".
    var interconnect: String?
    var isSolidState: Bool?
    var firmware: String?

    /// Nil when the dictionaries describe nothing worth showing.
    static func make(device: [String: Any]?, protocolInfo: [String: Any]?) -> DiskDriveInfo? {
        func text(_ dictionary: [String: Any]?, _ key: String) -> String? {
            guard let value = (dictionary?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let vendor = text(device, "Vendor Name")
        let product = text(device, "Product Name")
        var model = product
        if let vendor, let product, !product.localizedCaseInsensitiveContains(vendor) {
            model = "\(vendor) \(product)"
        } else if product == nil {
            model = vendor
        }
        let isSolidState: Bool?
        switch text(device, "Medium Type") {
        case "Solid State": isSolidState = true
        case "Rotational": isSolidState = false
        default: isSolidState = nil
        }
        let info = DiskDriveInfo(model: model,
                                 interconnect: text(protocolInfo, "Physical Interconnect"),
                                 isSolidState: isSolidState,
                                 firmware: text(device, "Product Revision Level"))
        return info == DiskDriveInfo() ? nil : info
    }

    /// Walks up the IOService plane from the volume's media ("disk3s1s1": APFS
    /// snapshot → volume → container → partition → whole disk → driver) to the first
    /// block storage device. About 1 ms; nil for network volumes or when the walk
    /// finds no device.
    static func read(bsdName: String) -> DiskDriveInfo? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        // A registry path is a handful of levels; the bound only guards against a cycle.
        var depth = 0
        while entry != 0, depth < 32 {
            depth += 1
            if IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                defer { IOObjectRelease(entry) }
                func dictionary(_ key: String) -> [String: Any]? {
                    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [String: Any]
                }
                return make(device: dictionary("Device Characteristics"),
                            protocolInfo: dictionary("Protocol Characteristics"))
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = result == KERN_SUCCESS ? parent : 0
        }
        if entry != 0 { IOObjectRelease(entry) }
        return nil
    }
}
