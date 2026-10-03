import CoreAudio
import Foundation

enum AudioDirection: Hashable, Sendable {
    case input
    case output
}

struct AudioDevice: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let name: String
    let directions: Set<AudioDirection>
    let supportsVolume: Bool
    let supportsMute: Bool

    static func directions(inputChannelCount: UInt32, outputChannelCount: UInt32) -> Set<AudioDirection> {
        var result = Set<AudioDirection>()
        if inputChannelCount > 0 { result.insert(.input) }
        if outputChannelCount > 0 { result.insert(.output) }
        return result
    }

    static func outputDevices(in devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { $0.directions.contains(.output) }
    }

    static func inputDevices(in devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { $0.directions.contains(.input) }
    }
}

/// What changed in the audio hardware. Device changes need a full
/// re-enumeration; control changes only need the default output's volume
/// and mute read again.
enum AudioHardwareChange: Equatable, Sendable {
    case devices
    case outputControls
}

/// Volume and mute of a single output device, read without enumerating devices.
struct AudioOutputControls: Equatable, Sendable {
    var volume: Float?
    var muted: Bool?
}

struct AudioDeviceState: Equatable, Sendable {
    var devices: [AudioDevice]
    var defaultInputID: AudioObjectID?
    var defaultOutputID: AudioObjectID?
    var outputVolume: Float?
    var outputMuted: Bool?
    var outputControlMessage: String?

    var outputControls: AudioOutputControls {
        get { AudioOutputControls(volume: outputVolume, muted: outputMuted) }
        set {
            outputVolume = newValue.volume
            outputMuted = newValue.muted
        }
    }

    static var empty: AudioDeviceState {
        AudioDeviceState(
            devices: [],
            defaultInputID: nil,
            defaultOutputID: nil,
            outputVolume: nil,
            outputMuted: nil,
            outputControlMessage: AudioControlError.deviceUnavailable.message
        )
    }
}
