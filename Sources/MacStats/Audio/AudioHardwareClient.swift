import CoreAudio
import Foundation

enum AudioControlError: Error, Equatable {
    case unsupportedControl(String)
    case unwritableControl(String)
    case deviceUnavailable
    case osStatus(OSStatus)

    var message: String {
        switch self {
        case let .unsupportedControl(message), let .unwritableControl(message): return message
        case .deviceUnavailable: return "No output device is currently available."
        case let .osStatus(status): return "macOS could not change this audio setting (error \(status))."
        }
    }
}

protocol AudioHardwareClient: AnyObject {
    func readDeviceState() throws -> AudioDeviceState
    func setDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) throws
    func setOutputVolume(_ value: Float, deviceID: AudioObjectID) throws
    func setOutputMuted(_ muted: Bool, deviceID: AudioObjectID) throws
    func startObserving(_ handler: @escaping () -> Void)
    func stopObserving()
}

/// Thin Core Audio adapter. It contains C-property details so the observable
/// service and SwiftUI can be exercised with a fake instead of physical audio
/// hardware.
final class SystemAudioHardwareClient: AudioHardwareClient {
    private let observationQueue = DispatchQueue(label: "com.macstats.audio-observation")
    private var observers: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    func readDeviceState() throws -> AudioDeviceState {
        let inputID = try defaultDeviceID(for: .input)
        let outputID = try defaultDeviceID(for: .output)
        let devices = try deviceIDs().compactMap(makeDevice)

        guard let outputID else {
            return AudioDeviceState(devices: devices, defaultInputID: inputID,
                                    defaultOutputID: nil, outputVolume: nil,
                                    outputMuted: nil,
                                    outputControlMessage: AudioControlError.deviceUnavailable.message)
        }

        let output = devices.first { $0.id == outputID }
        let volume = try readOptionalFloat(deviceID: outputID, selector: kAudioDevicePropertyVolumeScalar)
        let muted = try readOptionalBool(deviceID: outputID, selector: kAudioDevicePropertyMute)
        let message: String?
        if output?.supportsVolume != true {
            message = "\(output?.name ?? "The selected device") does not expose a master volume control."
        } else if output?.supportsMute != true {
            message = "\(output?.name ?? "The selected device") does not expose a master mute control."
        } else {
            message = nil
        }
        return AudioDeviceState(devices: devices, defaultInputID: inputID,
                                defaultOutputID: outputID, outputVolume: volume,
                                outputMuted: muted, outputControlMessage: message)
    }

    func setDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) throws {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             UInt32(MemoryLayout<AudioObjectID>.size), &deviceID))
    }

    func setOutputVolume(_ value: Float, deviceID: AudioObjectID) throws {
        var value = value
        try write(&value, deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar)
    }

    func setOutputMuted(_ muted: Bool, deviceID: AudioObjectID) throws {
        var value: UInt32 = muted ? 1 : 0
        try write(&value, deviceID: deviceID, selector: kAudioDevicePropertyMute)
    }

    func startObserving(_ handler: @escaping () -> Void) {
        stopObserving()

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, observationQueue, block
            ) == noErr else { continue }
            observers.append((address, block))
        }
    }

    func stopObserving() {
        for observer in observers {
            var address = observer.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, observationQueue, observer.block
            )
        }
        observers.removeAll()
    }

    private func deviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount))
        var result = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &result))
        return result
    }

    private func defaultDeviceID(for direction: AudioDirection) throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioObjectID = 0
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &id))
        return id == kAudioObjectUnknown ? nil : id
    }

    private func makeDevice(_ id: AudioObjectID) -> AudioDevice? {
        let directions = AudioDevice.directions(
            inputChannelCount: streamChannelCount(for: id, scope: kAudioDevicePropertyScopeInput),
            outputChannelCount: streamChannelCount(for: id, scope: kAudioDevicePropertyScopeOutput)
        )
        guard !directions.isEmpty else { return nil }
        return AudioDevice(id: id, name: deviceName(id),
                           directions: directions,
                           supportsVolume: directions.contains(.output) && hasWritableProperty(id, selector: kAudioDevicePropertyVolumeScalar),
                           supportsMute: directions.contains(.output) && hasWritableProperty(id, selector: kAudioDevicePropertyMute))
    }

    private func streamChannelCount(for id: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return 0 }

        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount) == noErr,
              byteCount >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        var storage = [UInt8](repeating: 0, count: Int(byteCount))
        return storage.withUnsafeMutableBytes { bytes in
            guard let list = bytes.baseAddress?.assumingMemoryBound(to: AudioBufferList.self),
                  AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, list) == noErr else { return 0 }
            return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
        }
    }

    private func deviceName(_ id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, &value) == noErr,
              let value else { return "Unknown device" }
        return value.takeRetainedValue() as String
    }

    private func readOptionalFloat(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Float? {
        guard hasProperty(deviceID, selector: selector, scope: kAudioDevicePropertyScopeOutput) else { return nil }
        var value: Float = 0
        var byteCount = UInt32(MemoryLayout<Float>.size)
        var address = outputAddress(selector)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value))
        return value
    }

    private func readOptionalBool(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Bool? {
        guard hasProperty(deviceID, selector: selector, scope: kAudioDevicePropertyScopeOutput) else { return nil }
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        var address = outputAddress(selector)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value))
        return value != 0
    }

    private func write<T>(_ value: UnsafeMutablePointer<T>, deviceID: AudioObjectID,
                          selector: AudioObjectPropertySelector) throws {
        var address = outputAddress(selector)
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw AudioControlError.unsupportedControl("The selected device does not expose this audio control.")
        }
        var writable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(deviceID, &address, &writable))
        guard writable.boolValue else { throw AudioControlError.unwritableControl("The selected device does not allow this audio control to change.") }
        try check(AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                             UInt32(MemoryLayout<T>.size), value))
    }

    private func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func hasProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(id, &address)
    }

    private func hasWritableProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = outputAddress(selector)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioControlError.osStatus(status) }
    }
}
