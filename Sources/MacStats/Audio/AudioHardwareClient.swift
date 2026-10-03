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
        case .deviceUnavailable: return L10n.string("No output device is currently available.")
        case let .osStatus(status): return L10n.string("macOS could not change this audio setting (error \(String(status))).")
        }
    }
}

protocol AudioHardwareClient: AnyObject {
    func readDeviceState() throws -> AudioDeviceState
    /// Reads only the volume and mute of one output device, without enumerating devices.
    func readOutputControls(deviceID: AudioObjectID) throws -> AudioOutputControls
    func setDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) throws
    func setOutputVolume(_ value: Float, deviceID: AudioObjectID) throws
    func setOutputMuted(_ muted: Bool, deviceID: AudioObjectID) throws
    func startObserving(_ handler: @escaping (AudioHardwareChange) -> Void)
    func stopObserving()
}

/// Element-level Core Audio property access. Kept behind a protocol so the
/// main-element / per-channel fallback can be exercised without hardware.
protocol AudioPropertyAccess {
    func hasProperty(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) -> Bool
    func isSettable(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) -> Bool
    func readFloat(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws -> Float
    func readFlag(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws -> Bool
    func writeFloat(_ value: Float, _ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws
    func writeFlag(_ value: Bool, _ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws
    /// The device's preferred stereo pair, or nil when it does not report one.
    func preferredStereoChannels(objectID: AudioObjectID) -> [AudioObjectPropertyElement]?
}

/// Where a device exposes one output control. Many USB and Bluetooth devices
/// have no main-element volume or mute and expose them per channel instead.
struct AudioOutputControlElements: Equatable {
    let elements: [AudioObjectPropertyElement]
    let isSettable: Bool
}

/// Reads and writes output volume and mute on the main element when it is
/// settable, otherwise on the device's stereo channels.
struct AudioOutputControlDriver {
    static let fallbackStereoChannels: [AudioObjectPropertyElement] = [1, 2]

    let properties: AudioPropertyAccess

    func elements(for selector: AudioObjectPropertySelector, deviceID: AudioObjectID) -> AudioOutputControlElements? {
        let groups = [[kAudioObjectPropertyElementMain], channels(deviceID)]
        for group in groups {
            let settable = group.filter { properties.isSettable(Self.address(selector, $0), objectID: deviceID) }
            if !settable.isEmpty { return AudioOutputControlElements(elements: settable, isSettable: true) }
        }
        // A read-only control is still worth showing.
        for group in groups {
            let readable = group.filter { properties.hasProperty(Self.address(selector, $0), objectID: deviceID) }
            if !readable.isEmpty { return AudioOutputControlElements(elements: readable, isSettable: false) }
        }
        return nil
    }

    /// Every element that may carry volume or mute, for change listeners.
    func observableAddresses(deviceID: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let elements = [kAudioObjectPropertyElementMain] + channels(deviceID)
        return [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].flatMap { selector in
            elements.map { Self.address(selector, $0) }
                .filter { properties.hasProperty($0, objectID: deviceID) }
        }
    }

    func readControls(deviceID: AudioObjectID) throws -> AudioOutputControls {
        AudioOutputControls(volume: try readVolume(deviceID: deviceID),
                            muted: try readMuted(deviceID: deviceID))
    }

    /// Per-channel devices report the loudest channel, as the system volume does.
    func readVolume(deviceID: AudioObjectID) throws -> Float? {
        guard let control = elements(for: kAudioDevicePropertyVolumeScalar, deviceID: deviceID) else { return nil }
        return try channelVolumes(control, deviceID: deviceID).max()
    }

    /// Per-channel devices count as muted only when every channel is muted.
    func readMuted(deviceID: AudioObjectID) throws -> Bool? {
        guard let control = elements(for: kAudioDevicePropertyMute, deviceID: deviceID) else { return nil }
        return try control.elements.allSatisfy {
            try properties.readFlag(Self.address(kAudioDevicePropertyMute, $0), objectID: deviceID)
        }
    }

    /// Per-channel devices keep their balance: the loudest channel moves to
    /// `value` and the others are scaled with it.
    func setVolume(_ value: Float, deviceID: AudioObjectID) throws {
        let control = try settableElements(for: kAudioDevicePropertyVolumeScalar, deviceID: deviceID)
        let current = control.elements.count > 1 ? try channelVolumes(control, deviceID: deviceID) : []
        let loudest = current.max() ?? 0
        for (index, element) in control.elements.enumerated() {
            let target = loudest > 0 ? current[index] / loudest * value : value
            try properties.writeFloat(min(max(target, 0), 1),
                                      Self.address(kAudioDevicePropertyVolumeScalar, element), objectID: deviceID)
        }
    }

    func setMuted(_ muted: Bool, deviceID: AudioObjectID) throws {
        let control = try settableElements(for: kAudioDevicePropertyMute, deviceID: deviceID)
        for element in control.elements {
            try properties.writeFlag(muted, Self.address(kAudioDevicePropertyMute, element), objectID: deviceID)
        }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func channels(_ deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        let preferred = properties.preferredStereoChannels(objectID: deviceID)?
            .filter { $0 != kAudioObjectPropertyElementMain }
        guard let preferred, !preferred.isEmpty else { return Self.fallbackStereoChannels }
        return preferred
    }

    private func channelVolumes(_ control: AudioOutputControlElements, deviceID: AudioObjectID) throws -> [Float] {
        try control.elements.map {
            try properties.readFloat(Self.address(kAudioDevicePropertyVolumeScalar, $0), objectID: deviceID)
        }
    }

    private func settableElements(for selector: AudioObjectPropertySelector,
                                  deviceID: AudioObjectID) throws -> AudioOutputControlElements {
        guard let control = elements(for: selector, deviceID: deviceID) else {
            throw AudioControlError.unsupportedControl(L10n.string("The selected device does not expose this audio control."))
        }
        guard control.isSettable else {
            throw AudioControlError.unwritableControl(L10n.string("The selected device does not allow this audio control to change."))
        }
        return control
    }
}

/// Thin Core Audio adapter. It contains C-property details so the observable
/// service and SwiftUI can be exercised with a fake instead of physical audio
/// hardware.
final class SystemAudioHardwareClient: AudioHardwareClient {
    private struct Listener {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let observationQueue = DispatchQueue(label: "com.macstats.audio-observation")
    private let controls = AudioOutputControlDriver(properties: CoreAudioPropertyAccess())
    // Listener bookkeeping is only touched on the main thread: Core Audio
    // delivers on `observationQueue` and each listener block hops to main.
    private var changeHandler: ((AudioHardwareChange) -> Void)?
    private var systemListeners: [Listener] = []
    private var outputListeners: [Listener] = []

    deinit {
        stopObserving()
    }

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
        let current = try readOutputControls(deviceID: outputID)
        let message: String?
        if output?.supportsVolume != true {
            message = output.map { L10n.string("\($0.name) does not expose an adjustable volume control.") }
                ?? L10n.string("The selected device does not expose an adjustable volume control.")
        } else if output?.supportsMute != true {
            message = output.map { L10n.string("\($0.name) does not expose an adjustable mute control.") }
                ?? L10n.string("The selected device does not expose an adjustable mute control.")
        } else {
            message = nil
        }
        return AudioDeviceState(devices: devices, defaultInputID: inputID,
                                defaultOutputID: outputID, outputVolume: current.volume,
                                outputMuted: current.muted, outputControlMessage: message)
    }

    func readOutputControls(deviceID: AudioObjectID) throws -> AudioOutputControls {
        try controls.readControls(deviceID: deviceID)
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
        try controls.setVolume(value, deviceID: deviceID)
    }

    func setOutputMuted(_ muted: Bool, deviceID: AudioObjectID) throws {
        try controls.setMuted(muted, deviceID: deviceID)
    }

    func startObserving(_ handler: @escaping (AudioHardwareChange) -> Void) {
        stopObserving()
        changeHandler = handler

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        for selector in selectors {
            let address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let listener = addListener(objectID: AudioObjectID(kAudioObjectSystemObject),
                                          address: address, change: .devices) {
                systemListeners.append(listener)
            }
        }
        observeDefaultOutputControls()
    }

    func stopObserving() {
        changeHandler = nil
        removeListeners(systemListeners + outputListeners)
        systemListeners.removeAll()
        outputListeners.removeAll()
    }

    /// Moves the volume and mute listeners to whichever device is now the
    /// default output, so volume keys and Control Center stay in sync.
    private func observeDefaultOutputControls() {
        removeListeners(outputListeners)
        outputListeners.removeAll()
        guard changeHandler != nil, let outputID = try? defaultDeviceID(for: .output) else { return }
        outputListeners = controls.observableAddresses(deviceID: outputID).compactMap {
            addListener(objectID: outputID, address: $0, change: .outputControls)
        }
    }

    private func deliver(_ change: AudioHardwareChange) {
        guard let changeHandler else { return }
        // The default output, or the controls it exposes, may change with the device list.
        if change == .devices { observeDefaultOutputControls() }
        changeHandler(change)
    }

    private func addListener(objectID: AudioObjectID, address: AudioObjectPropertyAddress,
                             change: AudioHardwareChange) -> Listener? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.deliver(change) }
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, observationQueue, block) == noErr else {
            return nil
        }
        return Listener(objectID: objectID, address: address, block: block)
    }

    private func removeListeners(_ listeners: [Listener]) {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, observationQueue, listener.block)
        }
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
        let isOutput = directions.contains(.output)
        return AudioDevice(id: id, name: deviceName(id),
                           directions: directions,
                           supportsVolume: isOutput && isSettable(kAudioDevicePropertyVolumeScalar, deviceID: id),
                           supportsMute: isOutput && isSettable(kAudioDevicePropertyMute, deviceID: id))
    }

    private func isSettable(_ selector: AudioObjectPropertySelector, deviceID: AudioObjectID) -> Bool {
        controls.elements(for: selector, deviceID: deviceID)?.isSettable == true
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
              let value else { return L10n.string("Unknown device") }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioControlError.osStatus(status) }
    }
}

/// `AudioPropertyAccess` backed by the Core Audio HAL.
struct CoreAudioPropertyAccess: AudioPropertyAccess {
    func hasProperty(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) -> Bool {
        guard hasProperty(address, objectID: objectID) else { return false }
        var address = address
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(objectID, &address, &writable) == noErr && writable.boolValue
    }

    func readFloat(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws -> Float {
        var value: Float = 0
        try read(&value, address, objectID: objectID)
        return value
    }

    func readFlag(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws -> Bool {
        var value: UInt32 = 0
        try read(&value, address, objectID: objectID)
        return value != 0
    }

    func writeFloat(_ value: Float, _ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws {
        var value = value
        try write(&value, address, objectID: objectID)
    }

    func writeFlag(_ value: Bool, _ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws {
        var value: UInt32 = value ? 1 : 0
        try write(&value, address, objectID: objectID)
    }

    func preferredStereoChannels(objectID: AudioObjectID) -> [AudioObjectPropertyElement]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var channels: (UInt32, UInt32) = (0, 0)
        var byteCount = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &channels) == noErr else { return nil }
        return [channels.0, channels.1]
    }

    private func read<T>(_ value: UnsafeMutablePointer<T>, _ address: AudioObjectPropertyAddress,
                         objectID: AudioObjectID) throws {
        var address = address
        var byteCount = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, value))
    }

    private func write<T>(_ value: UnsafeMutablePointer<T>, _ address: AudioObjectPropertyAddress,
                          objectID: AudioObjectID) throws {
        var address = address
        try check(AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<T>.size), value))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioControlError.osStatus(status) }
    }
}
