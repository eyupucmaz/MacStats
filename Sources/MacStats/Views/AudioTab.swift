import CoreAudio
import SwiftUI

struct AudioTab: View {
    @EnvironmentObject private var audioDevices: AudioDeviceService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection(title: "Output", direction: .output)
            Divider()
            deviceSection(title: "Input", direction: .input)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("App Mixer", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Text("Application mixing requires macOS 14.2 or later. Browser tabs are controlled as one browser app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = audioDevices.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func deviceSection(title: String, direction: AudioDirection) -> some View {
        let devices = direction == .output
            ? AudioDevice.outputDevices(in: audioDevices.state.devices)
            : AudioDevice.inputDevices(in: audioDevices.state.devices)
        let selected = direction == .output ? audioDevices.state.defaultOutputID : audioDevices.state.defaultInputID
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker(title, selection: Binding(
                get: { selected ?? 0 },
                set: { audioDevices.selectDefaultDevice($0, direction: direction) }
            )) {
                if devices.isEmpty { Text("No device available").tag(AudioObjectID(0)) }
                ForEach(devices) { device in Text(device.name).tag(device.id) }
            }
            .disabled(devices.isEmpty)
            if direction == .output {
                Slider(value: Binding(
                    get: { Double(audioDevices.state.outputVolume ?? 0) },
                    set: { audioDevices.setOutputVolume(Float($0)) }
                ), in: 0...1)
                .disabled(audioDevices.state.outputVolume == nil)
                Toggle("Mute", isOn: Binding(
                    get: { audioDevices.state.outputMuted ?? false },
                    set: { audioDevices.setOutputMuted($0) }
                ))
                .disabled(audioDevices.state.outputMuted == nil)
                if let message = audioDevices.state.outputControlMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
