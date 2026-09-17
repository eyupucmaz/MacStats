import Combine
import CoreAudio
import Foundation

final class AudioDeviceService: ObservableObject {
    @Published private(set) var state: AudioDeviceState
    @Published private(set) var errorMessage: String?

    private let hardware: AudioHardwareClient

    init(hardware: AudioHardwareClient = SystemAudioHardwareClient()) {
        self.hardware = hardware
        state = .empty
        hardware.startObserving { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        refresh()
    }

    deinit {
        hardware.stopObserving()
    }

    func refresh() {
        do {
            state = try hardware.readDeviceState()
        } catch let error as AudioControlError {
            errorMessage = error.message
        } catch {
            errorMessage = "MacStats could not read the current audio devices."
        }
    }

    func selectDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) {
        mutate { try hardware.setDefaultDevice(id, direction: direction) }
    }

    func setOutputVolume(_ value: Float) {
        guard let id = state.defaultOutputID else {
            errorMessage = AudioControlError.deviceUnavailable.message
            return
        }
        mutate { try hardware.setOutputVolume(min(max(value, 0), 1), deviceID: id) }
    }

    func setOutputMuted(_ muted: Bool) {
        guard let id = state.defaultOutputID else {
            errorMessage = AudioControlError.deviceUnavailable.message
            return
        }
        mutate { try hardware.setOutputMuted(muted, deviceID: id) }
    }

    private func mutate(_ operation: () throws -> Void) {
        errorMessage = nil
        do {
            try operation()
        } catch let error as AudioControlError {
            errorMessage = error.message
        } catch {
            errorMessage = "macOS could not change this audio setting."
        }
        refresh()
    }
}
