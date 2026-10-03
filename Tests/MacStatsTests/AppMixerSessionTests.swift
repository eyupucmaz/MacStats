import CoreAudio
import XCTest
@testable import MacStats

/// The parts of `AppMixerSession` reachable without creating real process taps:
/// gain mapping, format checks and the cleanup when setup fails on its first
/// Core Audio query. The success path, `stop()` after a running stream and
/// cleanup after a tap or aggregate device was created all need live Core Audio
/// objects and Screen & System Audio Recording permission, so they are not
/// covered here.
final class AppMixerSessionTests: XCTestCase {

    private func process(gain: Float, muted: Bool = false) -> AppMixerProcess {
        AppMixerProcess(id: 1, processID: 100, name: "App", gain: gain, muted: muted)
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

    // MARK: - Setup failure

    func testUnknownOutputDeviceFailsCleanly() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("AppMixerSession needs macOS 14.2") }
        // The device UID lookup fails before any tap exists; init must throw, not
        // trap, and the partially built session must tear down without touching
        // Core Audio objects it never created.
        XCTAssertThrowsError(try AppMixerSession(outputDeviceID: AudioObjectID(kAudioObjectUnknown),
                                                 processes: [process(gain: 1)])) { error in
            XCTAssertEqual(error as? AppMixerError, .unavailable("MacStats could not identify an audio device."))
        }
    }

    func testStringOfAnUnknownObjectThrows() {
        XCTAssertThrowsError(try AppMixerCoreAudio.string(of: AudioObjectID(kAudioObjectUnknown),
                                                          selector: kAudioDevicePropertyDeviceUID))
    }
}
