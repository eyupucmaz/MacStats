import Foundation

/// Labels and state decisions for the Audio tab, kept out of the view so they
/// can be unit-tested.
enum AudioTabPresentation {
    /// `@AppStorage` key for whether the App Mixer section is expanded — the
    /// only audio preference MacStats persists.
    static let mixerExpandedKey = "audioMixerExpanded"

    static var outputVolumeLabel: String { L10n.string("Output volume") }
    static var outputMuteLabel: String { L10n.string("Mute output") }
    static var refreshLabel: String { L10n.string("Refresh audio devices") }
    static var emptyDevicesMessage: String { L10n.string("No audio devices found. Connect a device or refresh.") }

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
        return L10n.string("\(String(Int((clamped * 100).rounded()))) percent")
    }

    /// The accessibility value of a volume slider.
    static func volumeValue(level: Float?, muted: Bool?) -> String {
        guard let level else { return L10n.string("Unavailable") }
        let percent = percentText(level)
        return muted == true ? L10n.string("Muted, \(percent)") : percent
    }

    static func volumeLabel(for appName: String) -> String {
        L10n.string("\(appName) volume")
    }

    static func muteLabel(for appName: String) -> String {
        L10n.string("Mute \(appName)")
    }

    /// VoiceOver label of a row's status icon, e.g. "Safari Muted".
    static func statusLabel(for appName: String, status: ProcessStatus) -> String {
        L10n.string("\(appName) \(status.text)")
    }

    struct ProcessStatus: Equatable {
        let systemImage: String
        let text: String
    }

    /// The service only lists apps it has tapped, so the status reflects what
    /// the mixer is doing to the stream rather than whether it is playing.
    static func status(for process: AppMixerProcess) -> ProcessStatus {
        if process.muted {
            return ProcessStatus(systemImage: "speaker.slash.fill", text: L10n.string("Muted"))
        }
        if process.gain <= 0 {
            return ProcessStatus(systemImage: "speaker.fill", text: L10n.string("Silent"))
        }
        return ProcessStatus(systemImage: "speaker.wave.2.fill", text: L10n.string("Mixing"))
    }
}
