import XCTest
@testable import MacStats

/// Tests for the hardware-independent parts of `SMCService`: value decoding,
/// key encoding, the temperature plausibility window and the rate-limited
/// temperature key probe. Nothing here opens the SMC.
final class SMCTests: XCTestCase {

    private func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
        SMCService.decode(type: SMCService.fourCharCode(type), bytes: bytes)
    }

    // MARK: - decode

    func testDecodesLittleEndianFloat() {
        let bytes = withUnsafeBytes(of: Float(45.5).bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(decode("flt ", bytes), 45.5)
    }

    func testRejectsShortOrNonFiniteFloat() {
        XCTAssertNil(decode("flt ", [0x00, 0x00, 0x80]))
        let nan = withUnsafeBytes(of: Float.nan.bitPattern.littleEndian) { Array($0) }
        XCTAssertNil(decode("flt ", nan))
        let inf = withUnsafeBytes(of: Float.infinity.bitPattern.littleEndian) { Array($0) }
        XCTAssertNil(decode("flt ", inf))
    }

    func testDecodesUnsignedBigEndianIntegers() {
        XCTAssertEqual(decode("ui8 ", [0x05]), 5)
        XCTAssertEqual(decode("ui16", [0x01, 0x02]), 258)
        XCTAssertEqual(decode("ui32", [0x00, 0x01, 0x00, 0x00]), 65_536)
        XCTAssertEqual(decode("ui64", [0, 0, 0, 0, 0, 0, 0x01, 0x00]), 256)
        XCTAssertEqual(decode("hex_", [0xFF]), 255)
        XCTAssertEqual(decode("char", [0x41]), 65)
    }

    func testDecodesSignedBigEndianIntegers() {
        XCTAssertEqual(decode("si8 ", [0xFF]), -1)
        XCTAssertEqual(decode("si8 ", [0x7F]), 127)
        XCTAssertEqual(decode("si16", [0xFF, 0xFE]), -2)
        XCTAssertEqual(decode("si32", [0x80, 0x00, 0x00, 0x00]), -2_147_483_648)
    }

    func testDecodesSignedFixedPoint() {
        XCTAssertEqual(decode("sp78", [0x2D, 0x80]), 45.5)
        XCTAssertEqual(decode("sp78", [0xFF, 0x80]), -0.5)
        XCTAssertEqual(decode("sp87", [0x01, 0x80]), 3)
        XCTAssertEqual(decode("sp96", [0x00, 0x40]), 1)
    }

    func testDecodesUnsignedFixedPoint() {
        XCTAssertEqual(decode("fpe2", [0x1F, 0x40]), 2000)
        XCTAssertEqual(decode("fp88", [0x01, 0x80]), 1.5)
        XCTAssertEqual(decode("fp1f", [0x80, 0x00]), 1)
    }

    func testRejectsUnknownTypes() {
        XCTAssertNil(decode("{fds", [0x01, 0x02]))
        XCTAssertNil(decode("ch8*", [0x41, 0x42]))
        XCTAssertNil(decode("spXY", [0x01, 0x02]))
        XCTAssertNil(decode("xp78", [0x01, 0x02]))
    }

    // MARK: - fourCharCode

    func testFourCharCodePacksBigEndian() {
        XCTAssertEqual(SMCService.fourCharCode("F0Ac"), 0x4630_4163)
        XCTAssertEqual(SMCService.fourCharCode("flt "), 0x666C_7420)
    }

    func testFourCharCodeUsesOnlyTheFirstFourBytes() {
        XCTAssertEqual(SMCService.fourCharCode("TC0Pxyz"), SMCService.fourCharCode("TC0P"))
    }

    func testFourCharCodeRoundTrips() {
        for key in SMCService.temperatureKeys + ["F0Ac", "sp78", "ui8 "] {
            XCTAssertEqual(SMCService.string(fromFourCharCode: SMCService.fourCharCode(key)), key)
        }
    }

    // MARK: - isPlausibleTemperature

    func testPlausibleTemperatureWindowIsInclusive() {
        XCTAssertTrue(SMCService.isPlausibleTemperature(10))
        XCTAssertTrue(SMCService.isPlausibleTemperature(45.5))
        XCTAssertTrue(SMCService.isPlausibleTemperature(120))
    }

    func testRejectsImplausibleTemperatures() {
        XCTAssertFalse(SMCService.isPlausibleTemperature(9.99))
        XCTAssertFalse(SMCService.isPlausibleTemperature(120.01))
        XCTAssertFalse(SMCService.isPlausibleTemperature(0))
        XCTAssertFalse(SMCService.isPlausibleTemperature(-40))
        XCTAssertFalse(SMCService.isPlausibleTemperature(.nan))
        XCTAssertFalse(SMCService.isPlausibleTemperature(.infinity))
    }

    // MARK: - TemperatureKeySelector

    /// Fake SMC: per-key readings plus a log of every key read.
    private final class FakeSensors {
        var readings: [String: Double] = [:]
        private(set) var reads: [String] = []

        func read(_ key: String) -> Double? {
            reads.append(key)
            return readings[key]
        }

        func reset() { reads.removeAll() }
    }

    private let candidates = ["A", "B", "C"]

    func testFirstReadProbesInOrderAndCachesTheFirstPlausibleKey() {
        let sensors = FakeSensors()
        sensors.readings = ["A": 500, "B": 50, "C": 60]
        var selector = SMCService.TemperatureKeySelector(candidates: candidates, reprobeInterval: 30)

        XCTAssertEqual(selector.read(now: 0, value: sensors.read), 50)
        XCTAssertEqual(sensors.reads, ["A", "B"])
        XCTAssertEqual(selector.cachedKey, "B")

        sensors.reset()
        XCTAssertEqual(selector.read(now: 1, value: sensors.read), 50)
        XCTAssertEqual(sensors.reads, ["B"])
    }

    func testProbeThatFindsNothingIsRateLimited() {
        let sensors = FakeSensors()
        var selector = SMCService.TemperatureKeySelector(candidates: candidates, reprobeInterval: 30)

        XCTAssertNil(selector.read(now: 0, value: sensors.read))
        XCTAssertEqual(sensors.reads, candidates)

        sensors.reset()
        for tick in 1..<30 {
            XCTAssertNil(selector.read(now: TimeInterval(tick), value: sensors.read))
        }
        XCTAssertEqual(sensors.reads, [], "no key may be read before the re-probe interval elapses")

        sensors.readings = ["C": 70]
        XCTAssertEqual(selector.read(now: 30, value: sensors.read), 70)
        XCTAssertEqual(sensors.reads, candidates)
        XCTAssertEqual(selector.cachedKey, "C")
    }

    func testFailingCachedKeyIsRetriedAloneUntilTheNextProbe() {
        let sensors = FakeSensors()
        sensors.readings = ["A": 40, "B": 55]
        var selector = SMCService.TemperatureKeySelector(candidates: candidates, reprobeInterval: 30)
        XCTAssertEqual(selector.read(now: 0, value: sensors.read), 40)

        // The cached key goes implausible within the window: only it is read.
        sensors.readings["A"] = 0
        sensors.reset()
        XCTAssertNil(selector.read(now: 10, value: sensors.read))
        XCTAssertNil(selector.read(now: 20, value: sensors.read))
        XCTAssertEqual(sensors.reads, ["A", "A"])

        // Once the interval has elapsed a full probe switches to the next key.
        sensors.reset()
        XCTAssertEqual(selector.read(now: 30, value: sensors.read), 55)
        XCTAssertEqual(sensors.reads, ["A", "A", "B"])
        XCTAssertEqual(selector.cachedKey, "B")
    }

    func testCachedKeyThatRecoversIsUsedWithoutProbing() {
        let sensors = FakeSensors()
        sensors.readings = ["A": 40]
        var selector = SMCService.TemperatureKeySelector(candidates: candidates, reprobeInterval: 30)
        XCTAssertEqual(selector.read(now: 0, value: sensors.read), 40)

        sensors.readings["A"] = nil
        XCTAssertNil(selector.read(now: 5, value: sensors.read))

        sensors.readings["A"] = 42
        sensors.reset()
        XCTAssertEqual(selector.read(now: 6, value: sensors.read), 42)
        XCTAssertEqual(sensors.reads, ["A"])
    }
}
