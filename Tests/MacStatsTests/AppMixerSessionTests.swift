import CoreAudio
import XCTest
@testable import MacStats

/// `AppMixerSession` against a fake `AppMixerHardware`: setup, the cleanup after
/// a failure at every step, idempotent teardown and the IOProc wiring, all
/// without creating real taps or needing audio capture permission. Gain
/// mapping and format checks run against the pure helpers.
final class AppMixerSessionTests: XCTestCase {

    private let outputID = AudioObjectID(50)

    private func process(gain: Float, muted: Bool = false) -> AppMixerProcess {
        AppMixerProcess(id: 1, processID: 100, name: "App", gain: gain, muted: muted)
    }

    private func processes(_ count: Int) -> [AppMixerProcess] {
        (0..<count).map { AppMixerProcess(id: AudioObjectID(10 + $0), processID: pid_t(100 + $0), name: "App \($0)", gain: 1, muted: false) }
    }

    private func format(id: AudioFormatID = kAudioFormatLinearPCM,
                        flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                        bits: UInt32 = 32) -> AudioStreamBasicDescription {
        var f = AudioStreamBasicDescription()
        f.mFormatID = id
        f.mFormatFlags = flags
        f.mBitsPerChannel = bits
        f.mChannelsPerFrame = 2
        return f
    }

    // MARK: - Gain

    func testEffectiveGainPassesThroughTheUnitRange() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: 0)), 0)
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: 0.35)), 0.35)
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: 1)), 1)
    }

    func testEffectiveGainIsClamped() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: 1.5)), 1)
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: -0.5)), 0)
    }

    func testMutedProcessIsSilentWhateverItsGain() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: 0.8, muted: true)), 0)
        XCTAssertEqual(AppMixerSession.effectiveGain(process(gain: 1.5, muted: true)), 0)
    }

    // MARK: - Format

    func testOnlyThirtyTwoBitFloatPCMIsAccepted() {
        XCTAssertTrue(AppMixerCoreAudio.isFloat32(format()))
        XCTAssertTrue(AppMixerCoreAudio.isFloat32(format(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved)))
        XCTAssertFalse(AppMixerCoreAudio.isFloat32(format(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)))
        XCTAssertFalse(AppMixerCoreAudio.isFloat32(format(bits: 64)))
        XCTAssertFalse(AppMixerCoreAudio.isFloat32(format(bits: 16)))
        XCTAssertFalse(AppMixerCoreAudio.isFloat32(format(id: kAudioFormatAppleLossless)))
    }

    func testStringOfAnUnknownObjectThrows() {
        XCTAssertThrowsError(try AppMixerCoreAudio.string(of: AudioObjectID(kAudioObjectUnknown),
                                                          selector: kAudioDevicePropertyDeviceUID))
    }

    // MARK: - Setup

    func testSuccessfulSetupTapsEveryProcessIntoAPrivateAggregateAndStartsIt() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()

        let session = try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)

        XCTAssertEqual(hardware.log, [
            .createTap(101), .createTap(102),
            .createAggregate(FakeAppMixerHardware.aggregateID),
            .createIOProc(on: FakeAppMixerHardware.aggregateID),
            .start(FakeAppMixerHardware.aggregateID)
        ])
        XCTAssertEqual(hardware.tapDescriptions.map(\.processes), [[10], [11]])
        XCTAssertEqual(hardware.tapDescriptions.map(\.name), ["MacStats App Mixer 100", "MacStats App Mixer 101"])
        XCTAssertTrue(hardware.tapDescriptions.allSatisfy { $0.isPrivate && $0.muteBehavior == .mutedWhenTapped })

        let aggregate = try XCTUnwrap(hardware.aggregateDescription)
        XCTAssertEqual(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(aggregate[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
        XCTAssertEqual(aggregate[kAudioAggregateDeviceMainSubDeviceKey] as? String, "output-uid")
        XCTAssertEqual(aggregate[kAudioAggregateDeviceSubDeviceListKey] as? [[String: String]], [[kAudioSubDeviceUIDKey: "output-uid"]])
        let taps = try XCTUnwrap(aggregate[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.map { $0[kAudioSubTapUIDKey] as? String }, ["tap-101", "tap-102"])
        XCTAssertEqual(taps.map { $0[kAudioSubTapDriftCompensationKey] as? Bool }, [true, true])
        XCTAssertTrue((aggregate[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix("com.eyupucmaz.MacStats.AppMixer.") == true)

        session.stop()
    }

    func testTheIOProcMixesTheTapsWithTheLatestGains() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        var apps = processes(2)
        apps[1].gain = 0.5
        let session = try AppMixerSession(outputDeviceID: outputID, processes: apps, hardware: hardware)
        defer { session.stop() }
        let input = TestBufferList([(2, [1, 2, 3, 4]), (2, [10, 20, 30, 40])])
        let output = TestBufferList([(2, [0, 0, 0, 0])])

        hardware.render(input, output)
        XCTAssertEqual(output.samples(0), [6, 12, 18, 24])

        var muted = apps[1]
        muted.muted = true
        session.apply(muted)
        hardware.render(input, output)  // ramps towards the new gain
        hardware.render(input, output)
        XCTAssertEqual(output.samples(0), [1, 2, 3, 4])
    }

    func testNonInterleavedTapsGetOneBufferPerChannel() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        hardware.tapFormat = format(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved)
        let session = try AppMixerSession(outputDeviceID: outputID, processes: processes(1), hardware: hardware)
        defer { session.stop() }
        let input = TestBufferList([(1, [1, 3]), (1, [2, 4])])
        let output = TestBufferList([(2, [0, 0, 0, 0])])

        hardware.render(input, output)

        XCTAssertEqual(output.samples(0), [1, 2, 3, 4])
    }

    // MARK: - Setup failure

    func testUnknownOutputDeviceFailsCleanly() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        // The real device UID lookup fails before any tap exists; init must throw,
        // not trap, and the partially built session must tear down without
        // touching Core Audio objects it never created.
        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: AudioObjectID(kAudioObjectUnknown),
                                                 processes: [process(gain: 1)])) { error in
            XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats could not identify an audio device."))
        }
    }

    func testOutputChecksFailBeforeAnythingIsCreated() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        for step in [FakeAppMixerHardware.Step.deviceUID, .requireFloatOutput] {
            let hardware = FakeAppMixerHardware()
            hardware.failing = step

            XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)) { error in
                XCTAssertEqual(error as? AppMixerError, FakeAppMixerHardware.failure, "\(step)")
            }
            XCTAssertEqual(hardware.log, [], "\(step)")
        }
    }

    func testFailedTapCreationDestroysTheEarlierTaps() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        hardware.failing = .createTap(2)

        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(3), hardware: hardware)) { error in
            XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats could not create an application audio tap."))
        }
        XCTAssertEqual(hardware.log, [.createTap(101), .createTap(nil), .destroyTap(101)])
    }

    func testFailedTapQueriesDestroyEveryTapCreatedSoFar() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        for step in [FakeAppMixerHardware.Step.tapUID(2), .tapFormat(2)] {
            let hardware = FakeAppMixerHardware()
            hardware.failing = step

            XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(3), hardware: hardware)) { error in
                XCTAssertEqual(error as? AppMixerError, FakeAppMixerHardware.failure, "\(step)")
            }
            XCTAssertEqual(hardware.log, [.createTap(101), .createTap(102), .destroyTap(101), .destroyTap(102)], "\(step)")
        }
    }

    func testMismatchedOrIntegerTapFormatsAreRefusedAndCleanedUp() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        var mono = format()
        mono.mChannelsPerFrame = 1
        let cases: [(formats: [AudioStreamBasicDescription], expected: [FakeAppMixerHardware.Call])] = [
            ([format(), mono], [.createTap(101), .createTap(102), .destroyTap(101), .destroyTap(102)]),
            ([format(flags: kAudioFormatFlagIsSignedInteger), format(flags: kAudioFormatFlagIsSignedInteger)],
             [.createTap(101), .createTap(102), .destroyTap(101), .destroyTap(102)])
        ]
        for (formats, expected) in cases {
            let hardware = FakeAppMixerHardware()
            hardware.tapFormats = formats

            XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)) { error in
                XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats received an unexpected application audio format."))
            }
            XCTAssertEqual(hardware.log, expected)
        }
    }

    func testFailedAggregateCreationDestroysTheTaps() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        hardware.failing = .createAggregate

        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)) { error in
            XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats could not create the application mixer output."))
        }
        XCTAssertEqual(hardware.log, [
            .createTap(101), .createTap(102), .createAggregate(nil),
            .destroyTap(101), .destroyTap(102)
        ])
    }

    func testFailedStereoPairLookupDestroysTheAggregateAndTaps() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        hardware.failing = .stereoPair

        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(1), hardware: hardware)) { error in
            XCTAssertEqual(error as? AppMixerError, FakeAppMixerHardware.failure)
        }
        XCTAssertEqual(hardware.log, [
            .createTap(101), .createAggregate(FakeAppMixerHardware.aggregateID),
            .destroyAggregate(FakeAppMixerHardware.aggregateID), .destroyTap(101)
        ])
    }

    func testFailedIOProcCreationDestroysTheAggregateAndTaps() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        hardware.failing = .createIOProc

        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)) { error in
            XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats could not prepare the application mixer stream."))
        }
        let aggregate = FakeAppMixerHardware.aggregateID
        XCTAssertEqual(hardware.log, [
            .createTap(101), .createTap(102), .createAggregate(aggregate), .createIOProc(on: aggregate),
            .destroyAggregate(aggregate), .destroyTap(101), .destroyTap(102)
        ])
    }

    func testFailedStartDestroysTheIOProcWithoutStoppingIt() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        hardware.failing = .start

        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)) { error in
            XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats could not start the application mixer stream."))
        }
        let aggregate = FakeAppMixerHardware.aggregateID
        XCTAssertEqual(hardware.log, [
            .createTap(101), .createTap(102), .createAggregate(aggregate), .createIOProc(on: aggregate), .start(aggregate),
            .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyTap(101), .destroyTap(102)
        ])
    }

    // MARK: - Teardown

    func testStopTearsDownInReverseOrderExactlyOnce() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        let session = try AppMixerSession(outputDeviceID: outputID, processes: processes(2), hardware: hardware)
        hardware.log.removeAll()

        session.stop()
        session.stop()
        session.apply(processes(2)[0])  // no renderer left: ignored

        let aggregate = FakeAppMixerHardware.aggregateID
        XCTAssertEqual(hardware.log, [
            .stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyTap(101), .destroyTap(102)
        ])
    }

    func testReleasingARunningSessionTearsItDown() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        var session: AppMixerSession? = try AppMixerSession(outputDeviceID: outputID, processes: processes(1), hardware: hardware)
        XCTAssertNotNil(session)
        hardware.log.removeAll()

        session = nil

        let aggregate = FakeAppMixerHardware.aggregateID
        XCTAssertEqual(hardware.log, [.stop(aggregate), .destroyIOProc(aggregate), .destroyAggregate(aggregate), .destroyTap(101)])
    }

    func testReleasingAStoppedSessionDoesNotTearDownAgain() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        let hardware = FakeAppMixerHardware()
        var session: AppMixerSession? = try AppMixerSession(outputDeviceID: outputID, processes: processes(1), hardware: hardware)
        session?.stop()
        hardware.log.removeAll()

        session = nil

        XCTAssertEqual(hardware.log, [])
    }
}

/// Records every Core Audio call the session makes and fails the one named
/// by `failing`. Taps are numbered from 101; the aggregate is always 200.
@available(macOS 14.2, *)
private final class FakeAppMixerHardware: AppMixerHardware {
    enum Step: Equatable {
        case deviceUID, requireFloatOutput, stereoPair
        /// 1-based: the n-th tap.
        case createTap(Int), tapUID(Int), tapFormat(Int)
        case createAggregate, createIOProc, start
    }

    enum Call: Equatable {
        case createTap(AudioObjectID?)
        case createAggregate(AudioObjectID?)
        case createIOProc(on: AudioObjectID)
        case start(AudioObjectID)
        case stop(AudioObjectID)
        case destroyIOProc(AudioObjectID)
        case destroyAggregate(AudioObjectID)
        case destroyTap(AudioObjectID)
    }

    static let aggregateID = AudioObjectID(200)
    static let failure = AppMixerError.unavailable("fake failure")
    /// Stands in for the IOProc ID Core Audio would hand out.
    private static let ioProc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }

    var failing: Step?
    var tapFormat: AudioStreamBasicDescription = {
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = 32
        format.mChannelsPerFrame = 2
        return format
    }()
    /// Per-tap formats; taps beyond the list use `tapFormat`.
    var tapFormats: [AudioStreamBasicDescription] = []

    var log: [Call] = []
    private(set) var tapDescriptions: [CATapDescription] = []
    private(set) var aggregateDescription: [String: Any]?
    private var ioBlock: AudioDeviceIOBlock?

    private func ordinal(of tapID: AudioObjectID) -> Int { Int(tapID) - 100 }

    func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        if failing == .deviceUID { throw Self.failure }
        return "output-uid"
    }

    func requireFloatOutput(_ deviceID: AudioObjectID) throws {
        if failing == .requireFloatOutput { throw Self.failure }
    }

    func stereoPair(of deviceID: AudioObjectID) throws -> (AppMixerChannel, AppMixerChannel) {
        if failing == .stereoPair { throw Self.failure }
        return (AppMixerChannel(buffer: 0, channel: 0), AppMixerChannel(buffer: 0, channel: 1))
    }

    func createProcessTap(_ description: CATapDescription, _ tapID: inout AudioObjectID) -> OSStatus {
        tapDescriptions.append(description)
        let ordinal = tapDescriptions.count
        guard failing != .createTap(ordinal) else {
            log.append(.createTap(nil))
            return kAudioHardwareUnspecifiedError
        }
        tapID = AudioObjectID(100 + ordinal)
        log.append(.createTap(tapID))
        return noErr
    }

    func tapUID(_ tapID: AudioObjectID) throws -> String {
        if failing == .tapUID(ordinal(of: tapID)) { throw Self.failure }
        return "tap-\(tapID)"
    }

    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        let index = ordinal(of: tapID) - 1
        if failing == .tapFormat(index + 1) { throw Self.failure }
        return index < tapFormats.count ? tapFormats[index] : tapFormat
    }

    func createAggregateDevice(_ description: [String: Any], _ deviceID: inout AudioObjectID) -> OSStatus {
        aggregateDescription = description
        guard failing != .createAggregate else {
            log.append(.createAggregate(nil))
            return kAudioHardwareUnspecifiedError
        }
        deviceID = Self.aggregateID
        log.append(.createAggregate(deviceID))
        return noErr
    }

    func createIOProcID(_ ioProcID: inout AudioDeviceIOProcID?, device: AudioObjectID, block: @escaping AudioDeviceIOBlock) -> OSStatus {
        log.append(.createIOProc(on: device))
        guard failing != .createIOProc else { return kAudioHardwareUnspecifiedError }
        ioBlock = block
        ioProcID = Self.ioProc
        return noErr
    }

    func start(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) -> OSStatus {
        log.append(.start(deviceID))
        return failing == .start ? kAudioHardwareUnspecifiedError : noErr
    }

    func stop(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) { log.append(.stop(deviceID)) }
    func destroyIOProcID(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) {
        ioBlock = nil
        log.append(.destroyIOProc(deviceID))
    }
    func destroyAggregateDevice(_ deviceID: AudioObjectID) { log.append(.destroyAggregate(deviceID)) }
    func destroyProcessTap(_ tapID: AudioObjectID) { log.append(.destroyTap(tapID)) }

    /// Runs one IOProc cycle the way Core Audio would.
    func render(_ input: TestBufferList, _ output: TestBufferList) {
        guard let ioBlock else { return XCTFail("no IOProc is installed") }
        withUnsafePointer(to: AudioTimeStamp()) { time in
            ioBlock(time, input.unsafePointer, time, output.list.unsafeMutablePointer, time)
        }
    }
}
