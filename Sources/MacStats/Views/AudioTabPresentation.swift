import Foundation

/// Labels and state decisions for the Audio tab, kept out of the view so they
/// can be unit-tested.
enum AudioTabPresentation {
    /// `@AppStorage` key for whether the App Mixer section is expanded — the
    /// only audio preference MacStats persists.
    static let mixerExpandedKey = "audioMixerExpanded"

    static let outputVolumeLabel = "Output volume"
    static let outputMuteLabel = "Mute output"
    static let refreshLabel = "Refresh audio devices"
    static let emptyDevicesMessage = "No audio devices found. Connect a device or refresh."

    enum DeviceContent: Equatable {
        /// Nothing was enumerated (or the read failed): show an empty state
        /// with a Refresh action instead of disabled pickers.
        case empty
        case devices
    }

    static func deviceContent(for state: AudioDeviceState) -> DeviceContent {
        state.devices.isEmpty ? .empty : .devices
    }

    /// "80 percent" — spelled out so VoiceOver does not read a bare number.
    static func percentText(_ level: Float) -> String {
        let clamped = min(max(level, 0), 1)
        return "\(Int((clamped * 100).rounded())) percent"
    }

    /// The accessibility value of a volume slider.
    static func volumeValue(level: Float?, muted: Bool?) -> String {
        guard let level else { return "Unavailable" }
        let percent = percentText(level)
        return muted == true ? "Muted, \(percent)" : percent
    }

    static func volumeLabel(for appName: String) -> String {
        "\(appName) volume"
    }

    static func muteLabel(for appName: String) -> String {
        "Mute \(appName)"
    }

    struct ProcessStatus: Equatable {
        let systemImage: String
        let text: String
    }

    /// The service only lists apps it has tapped, so the status reflects what
    /// the mixer is doing to the stream rather than whether it is playing.
    static func status(for process: AppMixerProcess) -> ProcessStatus {
        if process.muted {
            return ProcessStatus(systemImage: "speaker.slash.fill", text: "Muted")
        }
        if process.gain <= 0 {
            return ProcessStatus(systemImage: "speaker.fill", text: "Silent")
        }
        return ProcessStatus(systemImage: "speaker.wave.2.fill", text: "Mixing")
    }
}
