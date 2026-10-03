import CoreAudio
import Foundation

/// One running mix: a process tap per application, gathered into a private
/// aggregate device whose main sub-device is the real output device.
///
/// Every tap uses `.mutedWhenTapped`, so an app is only silenced while this
/// session's IOProc is reading its tap. The IOProc writes the gain-adjusted
/// sum of the taps straight into the output device's buffers. The system
/// default output is never changed: if MacStats stops, crashes or quits, the
/// taps stop being read and every app plays normally again.
///
/// Not thread-safe: the owner creates, mutates and stops a session on one
/// serial queue. Only the IOProc runs elsewhere, and it reads nothing but the
/// preallocated `AppMixerRenderer`.
@available(macOS 14.2, *)
final class AppMixerSession {
    let outputDeviceID: AudioObjectID
    let processes: [AppMixerProcess]

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var renderer: AppMixerRenderer?
    private var started = false
    private let hardware: AppMixerHardware

    init(outputDeviceID: AudioObjectID, processes: [AppMixerProcess], hardware: AppMixerHardware = CoreAudioAppMixerHardware()) throws {
        precondition(!processes.isEmpty)
        self.outputDeviceID = outputDeviceID
        self.processes = processes
        self.hardware = hardware

        do {
            let outputUID = try hardware.deviceUID(outputDeviceID)
            try hardware.requireFloatOutput(outputDeviceID)

            var tapUIDs: [String] = []
            var tapFormat: AudioStreamBasicDescription?
            for process in processes {
                let description = CATapDescription(stereoMixdownOfProcesses: [process.id])
                description.name = "MacStats App Mixer \(process.processID)"
                description.isPrivate = true
                description.muteBehavior = .mutedWhenTapped
                var tapID = AudioObjectID(kAudioObjectUnknown)
                guard hardware.createProcessTap(description, &tapID) == noErr else {
                    throw AppMixerError.unavailable(L10n.string("MacStats could not create an application audio tap."))
                }
                tapIDs.append(tapID)
                tapUIDs.append(try hardware.tapUID(tapID))
                let format = try hardware.tapFormat(tapID)
                if let tapFormat, tapFormat.mChannelsPerFrame != format.mChannelsPerFrame || tapFormat.mFormatFlags != format.mFormatFlags {
                    throw AppMixerError.unavailable(L10n.string("MacStats received an unexpected application audio format."))
                }
                tapFormat = format
            }
            guard let tapFormat, AppMixerCoreAudio.isFloat32(tapFormat) else {
                throw AppMixerError.unavailable(L10n.string("MacStats received an unexpected application audio format."))
            }

            // The output device is the main sub-device, so it clocks the
            // aggregate; the taps run on their own clock and are resampled
            // onto it through drift compensation.
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacStats App Mixer",
                kAudioAggregateDeviceUIDKey: "com.eyupucmaz.MacStats.AppMixer.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: tapUIDs.map {
                    [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true]
                }
            ]
            guard hardware.createAggregateDevice(description, &aggregateID) == noErr else {
                throw AppMixerError.unavailable(L10n.string("MacStats could not create the application mixer output."))
            }

            let buffersPerTap = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                ? Int(tapFormat.mChannelsPerFrame) : 1
            let (left, right) = try hardware.stereoPair(of: outputDeviceID)
            let layout = AppMixerLayout(tapCount: processes.count, buffersPerTap: max(buffersPerTap, 1), left: left, right: right)
            let renderer = AppMixerRenderer(layout: layout, gains: processes.map(Self.effectiveGain))
            self.renderer = renderer

            let status = hardware.createIOProcID(&ioProcID, device: aggregateID) { _, inputData, _, outputData, _ in
                renderer.render(input: inputData, output: outputData)
            }
            guard status == noErr, let ioProcID else {
                throw AppMixerError.unavailable(L10n.string("MacStats could not prepare the application mixer stream."))
            }
            guard hardware.start(aggregateID, ioProcID) == noErr else {
                throw AppMixerError.unavailable(L10n.string("MacStats could not start the application mixer stream."))
            }
            started = true
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    /// Idempotent. `AudioDeviceStop` returns only once the IOProc has
    /// finished, so the renderer can be released afterwards.
    func stop() {
        if started, let ioProcID { hardware.stop(aggregateID, ioProcID) }
        if let ioProcID { hardware.destroyIOProcID(aggregateID, ioProcID) }
        if aggregateID != kAudioObjectUnknown { hardware.destroyAggregateDevice(aggregateID) }
        for tapID in tapIDs { hardware.destroyProcessTap(tapID) }
        renderer?.deallocate()
        renderer = nil
        tapIDs.removeAll(); aggregateID = AudioObjectID(kAudioObjectUnknown); ioProcID = nil; started = false
    }

    func apply(_ process: AppMixerProcess) {
        guard let index = processes.firstIndex(where: { $0.processID == process.processID }) else { return }
        renderer?.setGain(Self.effectiveGain(process), at: index)
    }

    static func effectiveGain(_ process: AppMixerProcess) -> Float {
        process.muted ? 0 : min(max(process.gain, 0), 1)
    }
}

/// The Core Audio calls `AppMixerSession` makes, mirroring the C API's
/// status-and-out-parameter shape. Kept behind a protocol so setup, cleanup
/// after a partial failure and teardown can be exercised without creating
/// real taps or aggregate devices. Only setup and teardown go through it;
/// the IOProc block is handed to Core Audio unchanged.
@available(macOS 14.2, *)
protocol AppMixerHardware {
    func deviceUID(_ deviceID: AudioObjectID) throws -> String
    func requireFloatOutput(_ deviceID: AudioObjectID) throws
    func stereoPair(of deviceID: AudioObjectID) throws -> (AppMixerChannel, AppMixerChannel)
    func createProcessTap(_ description: CATapDescription, _ tapID: inout AudioObjectID) -> OSStatus
    func tapUID(_ tapID: AudioObjectID) throws -> String
    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription
    func createAggregateDevice(_ description: [String: Any], _ deviceID: inout AudioObjectID) -> OSStatus
    func createIOProcID(_ ioProcID: inout AudioDeviceIOProcID?, device: AudioObjectID, block: @escaping AudioDeviceIOBlock) -> OSStatus
    func start(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) -> OSStatus
    func stop(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID)
    func destroyIOProcID(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID)
    func destroyAggregateDevice(_ deviceID: AudioObjectID)
    func destroyProcessTap(_ tapID: AudioObjectID)
}

/// Production `AppMixerHardware`: forwards straight to Core Audio.
@available(macOS 14.2, *)
struct CoreAudioAppMixerHardware: AppMixerHardware {
    func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        try AppMixerCoreAudio.string(of: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func requireFloatOutput(_ deviceID: AudioObjectID) throws {
        try AppMixerCoreAudio.requireFloatOutput(deviceID)
    }

    func stereoPair(of deviceID: AudioObjectID) throws -> (AppMixerChannel, AppMixerChannel) {
        try AppMixerCoreAudio.stereoPair(of: deviceID)
    }

    func createProcessTap(_ description: CATapDescription, _ tapID: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateProcessTap(description, &tapID)
    }

    func tapUID(_ tapID: AudioObjectID) throws -> String {
        try AppMixerCoreAudio.string(of: tapID, selector: kAudioTapPropertyUID)
    }

    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try AppMixerCoreAudio.tapFormat(tapID)
    }

    func createAggregateDevice(_ description: [String: Any], _ deviceID: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
    }

    func createIOProcID(_ ioProcID: inout AudioDeviceIOProcID?, device: AudioObjectID, block: @escaping AudioDeviceIOBlock) -> OSStatus {
        AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, nil, block)
    }

    func start(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStart(deviceID, ioProcID)
    }

    func stop(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) {
        AudioDeviceStop(deviceID, ioProcID)
    }

    func destroyIOProcID(_ deviceID: AudioObjectID, _ ioProcID: AudioDeviceIOProcID) {
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// Thin Core Audio property helpers used by the mixer session and platform.
enum AppMixerCoreAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputID() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func uint32(of id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func objectIDs(of id: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(of id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else {
            throw AppMixerError.unavailable(L10n.string("MacStats could not identify an audio device."))
        }
        return value.takeRetainedValue() as String
    }

    static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    @available(macOS 14.2, *)
    static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else {
            throw AppMixerError.unavailable(L10n.string("MacStats could not read the application audio format."))
        }
        return format
    }

    /// The renderer writes 32-bit float samples, which is the virtual format
    /// of practically every output stream; refuse anything else rather than
    /// write floats into an integer stream.
    static func requireFloatOutput(_ deviceID: AudioObjectID) throws {
        let streams = objectIDs(of: deviceID, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard !streams.isEmpty else { throw AppMixerError.unavailable(L10n.string("The current output device has no output streams.")) }
        for stream in streams {
            var address = address(kAudioStreamPropertyVirtualFormat)
            var format = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr, isFloat32(format) else {
                throw AppMixerError.unavailable(L10n.string("The current output device uses an audio format the mixer does not support."))
            }
        }
    }

    /// Locates the output device's preferred stereo pair (falling back to
    /// channels 1 and 2) inside its output buffers. The aggregate's output
    /// buffers are exactly its only sub-device's, in the same order.
    static func stereoPair(of outputDeviceID: AudioObjectID) throws -> (AppMixerChannel, AppMixerChannel) {
        let channelsPerBuffer = outputChannelsPerBuffer(outputDeviceID)
        let total = channelsPerBuffer.reduce(0, +)
        guard total > 0 else { throw AppMixerError.unavailable(L10n.string("The current output device has no output channels.")) }

        var preferred: [UInt32] = [1, 2]
        var address = address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        var pair: [UInt32] = [0, 0]
        if AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &pair) == noErr,
           pair.allSatisfy({ $0 >= 1 && Int($0) <= total }) {
            preferred = pair
        }
        let left = locate(channel: Int(preferred[0]) - 1, in: channelsPerBuffer) ?? AppMixerChannel(buffer: 0, channel: 0)
        let right = total == 1
            ? left
            : locate(channel: min(Int(preferred[1]), total) - 1, in: channelsPerBuffer) ?? left
        return (left, right)
    }

    static func locate(channel: Int, in channelsPerBuffer: [Int]) -> AppMixerChannel? {
        var remaining = channel
        for (buffer, channels) in channelsPerBuffer.enumerated() {
            if remaining < channels { return AppMixerChannel(buffer: buffer, channel: remaining) }
            remaining -= channels
        }
        return nil
    }

    private static func outputChannelsPerBuffer(_ deviceID: AudioObjectID) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
