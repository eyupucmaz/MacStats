import Foundation
import IOKit

/// Minimal, fail-soft wrapper around the `AppleSMC` kernel service.
///
/// Every entry point degrades gracefully: when the service cannot be opened, a
/// key does not exist or the SMC rejects a request, reads return `nil`/`0`.
/// Nothing here traps.
///
/// Keys used by this file:
///   `FNum`   fan count                                          (ui8)
///   `F<n>Ac` fan n actual RPM                                    (flt / fpe2)
///   `F<n>Mn` fan n minimum RPM                                   (flt / fpe2)
///   `F<n>Mx` fan n maximum RPM                                   (flt / fpe2)
///   `F<n>Tg` fan n target RPM diagnostic                           (flt / fpe2)
///   `Tp09` `Tp0T` `Tp01` `Tp05` `Tp0D` `Tp0H` `Tg0f` `Tg0j`
///           Apple Silicon CPU/SoC die sensors                    (flt, °C)
///   `TC0P` `TC0D` `TCAD` Intel-era CPU proximity/die sensors      (sp78, °C)
final class SMCService: @unchecked Sendable {

    static let shared = SMCService()

    // MARK: - AppleSMC user-client interface

    /// `kSMCHandleYPCEvent` — the only selector the SMC user client needs.
    private static let selectorHandleYPCEvent: UInt32 = 2

    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadIndex: UInt8 = 8
    private static let cmdReadKeyInfo: UInt8 = 9

    /// 32-byte payload of `SMCKeyData_t`.
    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    private static let emptyBytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    /// C gives this struct 12 bytes (three bytes of tail padding after
    /// `dataAttributes`); Swift lays a nested struct out by *size*, not stride,
    /// so the padding has to be spelled out or `SMCKeyData` comes out 76 bytes
    /// and every SMC call fails.
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        private var pad0: UInt8 = 0
        private var pad1: UInt8 = 0
        private var pad2: UInt8 = 0
    }

    /// Mirrors the classic `SMCKeyData_t` (80 bytes); Swift lays these fields
    /// out in declaration order with C-compatible alignment.
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        private var pad0: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = SMCService.emptyBytes
    }

    /// A decoded raw SMC value: its four-character type plus its payload.
    struct RawValue {
        let key: String
        let type: String
        let bytes: [UInt8]
        let attributes: UInt8
    }

    // MARK: - State

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private let opened: Bool

    /// `dataSize`/`dataType` per key; key metadata never changes at runtime.
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]
    private var cachedFanCount: Int?
    private var cachedTemperatureKey: String?
    private var temperatureProbed = false

    /// `IOReturn` of the most recent kernel round trip; diagnostics only.
    private(set) var lastKernelStatus: kern_return_t = KERN_SUCCESS

    // MARK: - Lifecycle

    private init() {
        var conn: io_connect_t = 0
        var didOpen = false

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != IO_OBJECT_NULL {
            if IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess {
                didOpen = true
            }
            IOObjectRelease(service)
        }

        self.connection = didOpen ? conn : 0
        self.opened = didOpen
    }

    deinit {
        if opened, connection != 0 {
            IOServiceClose(connection)
        }
    }

    /// True when the `AppleSMC` user client was opened successfully.
    var isAvailable: Bool { opened }

    // MARK: - Public reads

    /// Number of fans reported by `FNum`; 0 on fanless machines or on failure.
    func fanCount() -> Int {
        lock.lock()
        if let cached = cachedFanCount {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let count = Int(readDouble("FNum") ?? 0)
        let clamped = (count > 0 && count < 16) ? count : 0

        lock.lock()
        cachedFanCount = clamped
        lock.unlock()
        return clamped
    }

    /// Actual RPM of fan 0 (`F0Ac`); `nil` when unavailable.
    func readFanRPM() -> Int? { readFanRPM(index: 0) }

    /// Actual RPM of the given fan (`F<n>Ac`).
    func readFanRPM(index: Int) -> Int? {
        guard let rpm = readDouble("F\(index)Ac"), rpm.isFinite, rpm >= 0 else { return nil }
        return Int(rpm.rounded())
    }

    /// Minimum RPM of the given fan (`F<n>Mn`).
    func readFanMinRPM(index: Int = 0) -> Int? {
        guard let rpm = readDouble("F\(index)Mn"), rpm.isFinite, rpm > 0 else { return nil }
        return Int(rpm.rounded())
    }

    /// Maximum RPM of the given fan (`F<n>Mx`).
    func readFanMaxRPM(index: Int = 0) -> Int? {
        guard let rpm = readDouble("F\(index)Mx"), rpm.isFinite, rpm > 0 else { return nil }
        return Int(rpm.rounded())
    }

    /// Target RPM currently programmed for the given fan (`F<n>Tg`).
    func readFanTargetRPM(index: Int = 0) -> Int? {
        guard let rpm = readDouble("F\(index)Tg"), rpm.isFinite, rpm >= 0 else { return nil }
        return Int(rpm.rounded())
    }

    /// CPU die temperature in Celsius, or `nil` when no sensor reads plausibly.
    /// Never synthesises a value.
    func readCPUTemperature() -> Double? {
        lock.lock()
        let cached = cachedTemperatureKey
        let probed = temperatureProbed
        lock.unlock()

        if let key = cached, let value = readDouble(key), Self.isPlausibleTemperature(value) {
            return value
        }
        // A cached key that stopped reading plausibly forces a re-probe.
        if probed && cached == nil { return nil }

        for key in Self.temperatureKeys {
            guard let value = readDouble(key), Self.isPlausibleTemperature(value) else { continue }
            lock.lock()
            cachedTemperatureKey = key
            temperatureProbed = true
            lock.unlock()
            return value
        }

        lock.lock()
        cachedTemperatureKey = nil
        temperatureProbed = true
        lock.unlock()
        return nil
    }

    /// The temperature key that is actually being used, once probed.
    var activeTemperatureKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedTemperatureKey
    }

    /// True when the key exists on this machine (metadata read succeeds).
    func hasKey(_ key: String) -> Bool {
        keyInfo(for: Self.fourCharCode(key)) != nil
    }

    /// Every key the SMC exposes, in index order (`#KEY` + `SMC_CMD_READ_INDEX`).
    /// Diagnostics only — never call this on the metrics path.
    func allKeys(limit: Int = 4096) -> [String] {
        guard opened, let total = readDouble("#KEY"), total > 0 else { return [] }
        var keys: [String] = []
        for index in 0..<min(Int(total), limit) {
            var input = SMCKeyData()
            input.data8 = Self.cmdReadIndex
            input.data32 = UInt32(index)
            guard let output = call(&input), output.result == 0, output.key != 0 else { continue }
            keys.append(Self.string(fromFourCharCode: output.key))
        }
        return keys
    }

    /// Reads a key without interpreting it — used by diagnostics.
    func readRaw(_ key: String) -> RawValue? {
        guard let value = read(key) else { return nil }
        return RawValue(
            key: key,
            type: Self.string(fromFourCharCode: value.type),
            bytes: value.bytes,
            attributes: keyInfo(for: Self.fourCharCode(key))?.dataAttributes ?? 0
        )
    }

    /// Numeric value of any key, decoded according to its SMC data type.
    func readValue(_ key: String) -> Double? { readDouble(key) }

    // MARK: - Key access

    private func readDouble(_ key: String) -> Double? {
        guard let value = read(key) else { return nil }
        return Self.decode(type: value.type, bytes: value.bytes)
    }

    private func read(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        guard opened else { return nil }
        let code = Self.fourCharCode(key)
        guard let info = keyInfo(for: code), info.dataSize > 0, info.dataSize <= 32 else { return nil }

        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.cmdReadBytes

        guard let output = call(&input), output.result == 0 else { return nil }
        return (info.dataType, Self.array(from: output.bytes, count: Int(info.dataSize)))
    }

    private func keyInfo(for code: UInt32) -> SMCKeyInfoData? {
        guard opened else { return nil }

        lock.lock()
        let cached = keyInfoCache[code]
        lock.unlock()
        if let cached { return cached.dataSize == 0 ? nil : cached }

        var input = SMCKeyData()
        input.key = code
        input.data8 = Self.cmdReadKeyInfo

        var info = SMCKeyInfoData()
        if let output = call(&input), output.result == 0 {
            info = output.keyInfo
        }

        lock.lock()
        keyInfoCache[code] = info      // a zero-sized entry caches "missing key"
        lock.unlock()
        return info.dataSize == 0 ? nil : info
    }

    /// One `IOConnectCallStructMethod` round trip, serialised on `lock`.
    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        guard opened else { return nil }
        var output = SMCKeyData()
        let size = MemoryLayout<SMCKeyData>.stride
        var outSize = size

        lock.lock()
        let result = IOConnectCallStructMethod(
            connection, Self.selectorHandleYPCEvent, &input, size, &output, &outSize
        )
        lastKernelStatus = result
        lock.unlock()

        return result == kIOReturnSuccess ? output : nil
    }

    // MARK: - Decoding

    /// CPU-die candidates, most specific first.
    /// `Tp09`/`Tp0T`/… are the M1–M3 core-cluster names; `Tp00`/`Tp04`/… are
    /// what M4/M5 expose instead. `Tg0f`/`Tg0j` are GPU-side and only used when
    /// no CPU sensor answers; `TC0P`/`TC0D`/`TCAD` are the Intel-era fallbacks.
    static let temperatureKeys = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H",
        "Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X",
        "Tg0f", "Tg0j",
        "TC0P", "TC0D", "TCAD"
    ]

    static func isPlausibleTemperature(_ value: Double) -> Bool {
        value.isFinite && value >= 10 && value <= 120
    }

    static func fourCharCode(_ key: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in key.utf8.prefix(4) { code = (code << 8) | UInt32(byte) }
        return code
    }

    static func string(fromFourCharCode code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// Decodes the SMC's data types. Apple Silicon returns `flt` for almost
    /// everything; the fixed-point families survive from Intel machines.
    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        let name = string(fromFourCharCode: type)
        switch name {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            // `flt` is little-endian IEEE-754 binary32.
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: raw))
            return value.isFinite ? value : nil
        case "ui8 ", "ui16", "ui32", "ui64", "hex_", "char":
            return Double(unsignedBigEndian(bytes))
        case "si8 ", "si16", "si32":
            return Double(signedBigEndian(bytes))
        default:
            // Fixed point: sp78 / sp87 / sp96 / fp88 / fpe2 / fp1f ...
            // 3rd char = integer bits, 4th char = fractional bits (hex digits);
            // an "s" prefix means the value is signed (two's complement).
            let chars = Array(name)
            guard chars.count == 4, chars[1] == "p",
                  let fractionBits = chars[3].hexDigitValue,
                  chars[2].hexDigitValue != nil else { return nil }
            let scale = Double(1 << fractionBits)
            if chars[0] == "s" {
                return Double(signedBigEndian(bytes)) / scale
            } else if chars[0] == "f" {
                return Double(unsignedBigEndian(bytes)) / scale
            }
            return nil
        }
    }

    private static func unsignedBigEndian(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes.prefix(8) { value = (value << 8) | UInt64(byte) }
        return value
    }

    private static func signedBigEndian(_ bytes: [UInt8]) -> Int64 {
        let slice = Array(bytes.prefix(8))
        guard !slice.isEmpty else { return 0 }
        let unsigned = unsignedBigEndian(slice)
        let bits = slice.count * 8
        guard bits < 64 else { return Int64(bitPattern: unsigned) }
        let signBit: UInt64 = 1 << UInt64(bits - 1)
        if unsigned & signBit != 0 {
            return Int64(unsigned) - Int64(1 << UInt64(bits))
        }
        return Int64(unsigned)
    }

    /// Well-known `SMCKeyData_t.result` codes.
    static func describe(result: UInt8) -> String {
        switch result {
        case 0x00: return "success"
        case 0x01: return "generic error"
        case 0x80: return "communication collision"
        case 0x81: return "spurious data"
        case 0x82: return "bad command"
        case 0x83: return "bad parameter"
        case 0x84: return "key not found"
        case 0x85: return "key not readable"
        case 0x86: return "key not writable"
        case 0x87: return "key size mismatch"
        case 0x88: return "framing error"
        case 0x89: return "bad argument"
        case 0xB7: return "timeout"
        case 0xB8: return "key index out of range"
        case 0xC0: return "bad function parameter"
        case 0xC7: return "device access error"
        case 0xCB: return "unsupported feature"
        case 0xCC: return "SMBus access error"
        default: return String(format: "error 0x%02X", result)
        }
    }

    /// Well-known `IOReturn` codes seen on the SMC user client.
    static func describe(kernel status: kern_return_t) -> String {
        switch status {
        case kIOReturnSuccess: return "success"
        case kIOReturnNotPrivileged: return "not privileged (root required)"
        case kIOReturnNotPermitted: return "operation not permitted"
        case kIOReturnBadArgument: return "bad argument"
        case kIOReturnUnsupported: return "unsupported"
        case kIOReturnNoDevice: return "no device"
        case kIOReturnError: return "general kernel error"
        default: return String(format: "IOReturn 0x%08X", UInt32(bitPattern: status))
        }
    }

    // MARK: - Byte conversion

    private static func array(from bytes: SMCBytes, count: Int) -> [UInt8] {
        var copy = bytes
        return withUnsafeBytes(of: &copy) { raw in
            (0..<min(max(count, 0), 32)).map { raw[$0] }
        }
    }

    /// Byte size of `SMCKeyData_t` as Swift lays it out — 80 on a correct build.
    static var keyDataStructSize: Int { MemoryLayout<SMCKeyData>.stride }
}
