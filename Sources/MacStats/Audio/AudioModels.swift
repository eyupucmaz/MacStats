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

struct AudioDeviceState: Equatable, Sendable {
    var devices: [AudioDevice]
    var defaultInputID: AudioObjectID?
    var defaultOutputID: AudioObjectID?
    var outputVolume: Float?
    var outputMuted: Bool?
    var outputControlMessage: String?

    static let empty = AudioDeviceState(
        devices: [],
        defaultInputID: nil,
        defaultOutputID: nil,
        outputVolume: nil,
        outputMuted: nil,
        outputControlMessage: "No output device is currently available."
    )
}
