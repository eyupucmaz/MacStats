import AppKit
import CoreAudio
import SwiftUI

struct AudioTab: View {
    @EnvironmentObject private var audioDevices: AudioDeviceService
    @EnvironmentObject private var appMixer: AppMixerService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection(title: "Output", direction: .output)
            Divider()
            deviceSection(title: "Input", direction: .input)
            Divider()
            appMixerSection
            if let error = audioDevices.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appMixerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("App Mixer", systemImage: "slider.horizontal.3").font(.headline)
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
        .onAppear { appMixer.refreshPermission() }
    }

    private var enableTitle: String {
        switch appMixer.phase {
        case .requestingPermission: return "Waiting for Permission…"
        case .starting: return "Starting…"
        case .off, .running: return "Enable App Mixer"
        }
    }

    private func processRow(_ process: AppMixerProcess) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.name).lineLimit(1)
                Spacer()
                Toggle("Mute", isOn: Binding(
                    get: { process.muted },
                    set: { appMixer.setMuted($0, for: process.processID) }
                )).labelsHidden()
            }
            Slider(value: Binding(
                get: { Double(process.gain) },
                set: { appMixer.setGain(Float($0), for: process.processID) }
            ), in: 0...1)
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
