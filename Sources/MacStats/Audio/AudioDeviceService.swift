import Combine
import CoreAudio
import Foundation

final class AudioDeviceService: ObservableObject {
    @Published private(set) var state: AudioDeviceState
    @Published private(set) var errorMessage: String?

    private static let readFailureMessage = "MacStats could not read the current audio devices."
    private static let writeFailureMessage = "macOS could not change this audio setting."

    private let hardware: AudioHardwareClient

    init(hardware: AudioHardwareClient = SystemAudioHardwareClient()) {
        self.hardware = hardware
        state = .empty
        hardware.startObserving { [weak self] change in
            DispatchQueue.main.async { self?.handle(change) }
        }
        refresh()
    }

    deinit {
        hardware.stopObserving()
    }

    func refresh() {
        perform(reload: reloadDevices)
    }

    func selectDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) {
        perform({ try hardware.setDefaultDevice(id, direction: direction) }, reload: reloadDevices)
    }

    func setOutputVolume(_ value: Float) {
        guard let id = state.defaultOutputID else {
            errorMessage = AudioControlError.deviceUnavailable.message
            return
        }
        // Volume writes arrive on every slider tick, so only the output's
        // controls are read back instead of re-enumerating every device.
        perform({ try hardware.setOutputVolume(min(max(value, 0), 1), deviceID: id) },
                reload: { try reloadOutputControls(deviceID: id) })
    }

    func setOutputMuted(_ muted: Bool) {
        guard let id = state.defaultOutputID else {
            errorMessage = AudioControlError.deviceUnavailable.message
            return
        }
        perform({ try hardware.setOutputMuted(muted, deviceID: id) },
                reload: { try reloadOutputControls(deviceID: id) })
    }

    private func handle(_ change: AudioHardwareChange) {
        switch change {
        case .devices:
            refresh()
        case .outputControls:
            guard let id = state.defaultOutputID else { return }
            perform(reload: { try reloadOutputControls(deviceID: id) })
        }
    }

    private func reloadDevices() throws {
        state = try hardware.readDeviceState()
    }

    private func reloadOutputControls(deviceID: AudioObjectID) throws {
        let controls = try hardware.readOutputControls(deviceID: deviceID)
        // The default output may have changed while the read was pending.
        guard state.defaultOutputID == deviceID else { return }
        state.outputControls = controls
    }

    /// Runs an optional write, then always reads the hardware back so the UI
    /// shows what the device actually accepted. `errorMessage` reflects the
    /// write failure if any, otherwise the read failure, and is cleared when
    /// both succeed.
    private func perform(_ operation: () throws -> Void = {}, reload: () throws -> Void) {
        var message: String?
        do {
            try operation()
        } catch {
            message = Self.message(for: error, fallback: Self.writeFailureMessage)
        }
        do {
            try reload()
        } catch {
            message = message ?? Self.message(for: error, fallback: Self.readFailureMessage)
        }
        errorMessage = message
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? AudioControlError)?.message ?? fallback
    }
}
