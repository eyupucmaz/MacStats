import Foundation
import IOKit

/// Minimal, fail-soft wrapper around the `AppleSMC` kernel service.
///
/// Every entry point degrades gracefully: when the service cannot be opened, a
/// key does not exist or the SMC rejects a request, reads return `nil`/`0`.
/// Nothing here traps.
///
/// Keys used by this file:
///   `F<n>Ac` fan n actual RPM                                    (flt / fpe2)
///   `Tp09` `Tp0T` `Tp01` `Tp05` `Tp0D` `Tp0H` `Tg0f` `Tg0j`
///           Apple Silicon CPU/SoC die sensors                    (flt, °C)
///   `TC0P` `TC0D` `TCAD` Intel-era CPU proximity/die sensors      (sp78, °C)
final class SMCService: @unchecked Sendable {

    static let shared = SMCService()

    // MARK: - AppleSMC user-client interface

    /// `kSMCHandleYPCEvent` — the only selector the SMC user client needs.
    private static let selectorHandleYPCEvent: UInt32 = 2

    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9

    /// `SMCKeyData_t.result` when the SMC does not know the key (`kSMCKeyNotFound`).
    private static let resultKeyNotFound: UInt8 = 0x84

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

    // MARK: - State

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private let opened: Bool

    /// `dataSize`/`dataType` per key; key metadata never changes at runtime.
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]

    /// Guards `temperatureSelector` for the whole probe. Separate from `lock`,
    /// which `call` takes for every round trip made while probing.
    private let temperatureLock = NSLock()
    private var temperatureSelector = TemperatureKeySelector(candidates: SMCService.temperatureKeys)

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

    /// Actual RPM of fan 0 (`F0Ac`); `nil` when unavailable.
    func readFanRPM() -> Int? { readFanRPM(index: 0) }

    /// Actual RPM of the given fan (`F<n>Ac`).
    func readFanRPM(index: Int) -> Int? {
        guard let rpm = readDouble("F\(index)Ac"), rpm.isFinite, rpm >= 0 else { return nil }
        return Int(rpm.rounded())
    }

    /// CPU die temperature in Celsius, or `nil` when no sensor reads plausibly.
    /// Never synthesises a value.
    func readCPUTemperature() -> Double? {
        temperatureLock.lock()
        defer { temperatureLock.unlock() }
        return temperatureSelector.read(now: ProcessInfo.processInfo.systemUptime) { readDouble($0) }
    }

    /// The temperature key that is actually being used, once probed.
    var activeTemperatureKey: String? {
        temperatureLock.lock()
        defer { temperatureLock.unlock() }
        return temperatureSelector.cachedKey
    }

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

        // Only a definitive answer is cached: metadata on success, or a
        // zero-sized entry for "key not found". A failed round trip or any
        // other SMC error may be transient, so the next read asks again.
        guard let output = call(&input) else { return nil }
        let info: SMCKeyInfoData
        switch output.result {
        case 0: info = output.keyInfo
        case Self.resultKeyNotFound: info = SMCKeyInfoData()
        default: return nil
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

    /// Remembers which candidate key reads plausibly and rate-limits the
    /// fallback probe over every candidate (each costs up to two SMC round
    /// trips). Pure state machine, so it is testable without an SMC.
    struct TemperatureKeySelector {
        /// Minimum seconds between two full probes.
        static let defaultReprobeInterval: TimeInterval = 30

        let candidates: [String]
        let reprobeInterval: TimeInterval
        private(set) var cachedKey: String?
        private var lastProbe: TimeInterval?

        init(candidates: [String], reprobeInterval: TimeInterval = Self.defaultReprobeInterval) {
            self.candidates = candidates
            self.reprobeInterval = reprobeInterval
        }

        /// `now` is a monotonic timestamp in seconds; `value` reads one key.
        mutating func read(now: TimeInterval, value: (String) -> Double?) -> Double? {
            if let key = cachedKey, let reading = value(key), SMCService.isPlausibleTemperature(reading) {
                return reading
            }
            // No cached key yet, or it stopped reading plausibly: probe every
            // candidate, but at most once per `reprobeInterval`. In between the
            // cached key (if any) keeps being retried on its own.
            if let lastProbe, now - lastProbe < reprobeInterval { return nil }
            lastProbe = now

            for key in candidates {
                guard let reading = value(key), SMCService.isPlausibleTemperature(reading) else { continue }
                cachedKey = key
                return reading
            }
            cachedKey = nil
            return nil
        }
    }

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

    // MARK: - Byte conversion

    private static func array(from bytes: SMCBytes, count: Int) -> [UInt8] {
        var copy = bytes
        return withUnsafeBytes(of: &copy) { raw in
            (0..<min(max(count, 0), 32)).map { raw[$0] }
        }
    }
}
