import AppKit
import CoreAudio
import SwiftUI

struct AudioTab: View {
    @EnvironmentObject private var audioDevices: AudioDeviceService
    @EnvironmentObject private var appMixer: AppMixerService
    @StateObject private var sliders = AudioSliderWriter()
    @AppStorage(AudioTabPresentation.mixerExpandedKey) private var mixerExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch AudioTabPresentation.deviceContent(for: audioDevices.state) {
            case .empty:
                emptyState
            case .devices:
                deviceSection(title: "Output", direction: .output)
                Divider()
                deviceSection(title: "Input", direction: .input)
                Divider()
                appMixerSection
            }
            if let error = audioDevices.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A held-back slider value must still reach Core Audio when the tab goes away.
        .onDisappear { sliders.flushAll() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No Audio Devices", systemImage: "speaker.slash").font(.headline)
            Text(AudioTabPresentation.emptyDevicesMessage)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh") { audioDevices.refresh() }
                .accessibilityLabel(AudioTabPresentation.refreshLabel)
        }
    }

    private var refreshButton: some View {
        Button { audioDevices.refresh() } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(AudioTabPresentation.refreshLabel)
        .accessibilityLabel(AudioTabPresentation.refreshLabel)
    }

    private var appMixerSection: some View {
        DisclosureGroup(isExpanded: $mixerExpanded) {
            appMixerContent
                .padding(.top, 4)
        } label: {
            Label("App Mixer", systemImage: "slider.horizontal.3").font(.headline)
        }
        .onAppear { appMixer.refreshPermission() }
    }

    private var appMixerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appMixer.capability == .requiresMacOS142 {
                Text("Application mixing requires macOS 14.2 or later.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if appMixer.isRunning {
                Button("Disable App Mixer") { appMixer.disable() }
                if appMixer.processes.isEmpty {
                    Text("No app is playing audio yet. Apps appear here when they start playing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(appMixer.processes) { process in processRow(process) }
                }
            } else {
                // Shown before the user enables the mixer, i.e. before macOS asks.
                Text("To set each app's volume, MacStats captures the sound apps send to your output and plays it back at the levels you choose. Audio is processed in memory on this Mac only; nothing is recorded, saved or sent anywhere. Browser tabs are controlled as one browser app.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appMixer.permission == .denied {
                    Text("Audio capture is turned off for MacStats. Allow it in Privacy & Security under Screen & System Audio Recording, then enable the mixer again.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { NSWorkspace.shared.open(AppMixerService.privacySettingsURL) }
                }
                Button(enableTitle) { Task { await appMixer.enable() } }
                    .disabled(appMixer.isBusy)
                if appMixer.phase == .requestingPermission {
                    Text("macOS may ask for permission to record system audio. If this window closes, reopen MacStats to see the mixer.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let status = appMixer.statusMessage, !(appMixer.permission == .denied && status == AppMixerService.deniedMessage) {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enableTitle: String {
        switch appMixer.phase {
        case .requestingPermission: return "Waiting for Permission…"
        case .starting: return "Starting…"
        case .off, .running: return "Enable App Mixer"
        }
    }

    private func processRow(_ process: AppMixerProcess) -> some View {
        let key = AudioSliderKey.app(process.processID)
        let gain = sliders.value(for: key, current: process.gain) ?? process.gain
        let status = AudioTabPresentation.status(for: process)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AudioAppIcon(processID: process.processID)
                Text(process.name).lineLimit(1)
                Image(systemName: status.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(status.text)
                    .accessibilityLabel("\(process.name) \(status.text)")
                Spacer()
                Toggle("Mute", isOn: Binding(
                    get: { process.muted },
                    set: { appMixer.setMuted($0, for: process.processID) }
                ))
                .accessibilityLabel(AudioTabPresentation.muteLabel(for: process.name))
            }
            Slider(value: Binding(
                get: { Double(gain) },
                set: { value in
                    sliders.send(Float(value), for: key) { appMixer.setGain($0, for: process.processID) }
                }
            ), in: 0...1, onEditingChanged: { editing in if !editing { sliders.flush(key) } })
            .accessibilityLabel(AudioTabPresentation.volumeLabel(for: process.name))
            .accessibilityValue(AudioTabPresentation.volumeValue(level: gain, muted: process.muted))
        }
    }

    @ViewBuilder
    private func deviceSection(title: String, direction: AudioDirection) -> some View {
        let devices = direction == .output
            ? AudioDevice.outputDevices(in: audioDevices.state.devices)
            : AudioDevice.inputDevices(in: audioDevices.state.devices)
        let selected = direction == .output ? audioDevices.state.defaultOutputID : audioDevices.state.defaultInputID
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if direction == .output { refreshButton }
            }
            Picker(title, selection: Binding<AudioObjectID?>(
                get: { selected },
                set: { id in if let id { audioDevices.selectDefaultDevice(id, direction: direction) } }
            )) {
                if devices.isEmpty || selected == nil {
                    Text(devices.isEmpty ? "No device available" : "None").tag(AudioObjectID?.none)
                }
                ForEach(devices) { device in Text(device.name).tag(Optional(device.id)) }
            }
            .disabled(devices.isEmpty)
            if direction == .output {
                outputControls
            }
        }
    }

    @ViewBuilder
    private var outputControls: some View {
        let volume = sliders.value(for: .output, current: audioDevices.state.outputVolume)
        Slider(value: Binding(
            get: { Double(volume ?? 0) },
            set: { value in
                sliders.send(Float(value), for: .output) { audioDevices.setOutputVolume($0) }
            }
        ), in: 0...1, onEditingChanged: { editing in if !editing { sliders.flush(.output) } })
        .disabled(audioDevices.state.outputVolume == nil)
        .accessibilityLabel(AudioTabPresentation.outputVolumeLabel)
        .accessibilityValue(AudioTabPresentation.volumeValue(level: volume, muted: audioDevices.state.outputMuted))
        Toggle("Mute", isOn: Binding(
            get: { audioDevices.state.outputMuted ?? false },
            set: { audioDevices.setOutputMuted($0) }
        ))
        .disabled(audioDevices.state.outputMuted == nil)
        .accessibilityLabel(AudioTabPresentation.outputMuteLabel)
        if let message = audioDevices.state.outputControlMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The app's Dock icon, looked up by pid; processes without one (daemons,
/// helpers) get a generic symbol. The name is shown next to it, so the icon is
/// hidden from VoiceOver.
private struct AudioAppIcon: View {
    let processID: pid_t

    var body: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: processID)?.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
