import CoreAudio
import XCTest
@testable import MacStats

final class AudioModelsTests: XCTestCase {
    /// A Core Audio device can expose a stream-configuration property with no
    /// streams. Only channels in that configuration make it an input or output.
    func testDirectionsIgnoreAnEmptyOutputStreamConfiguration() {
        XCTAssertEqual(
            AudioDevice.directions(inputChannelCount: 1, outputChannelCount: 0),
            Set([.input])
        )
    }

    /// Catches a regression where an input-only device is offered as a system output.
    func testOutputDevicesExcludeInputOnlyDevices() {
        let microphone = AudioDevice(id: 1, name: "Studio Microphone", directions: [.input],
                                     supportsVolume: false, supportsMute: false)
        let speakers = AudioDevice(id: 2, name: "MacBook Speakers", directions: [.output],
                                   supportsVolume: true, supportsMute: true)

        XCTAssertEqual(AudioDevice.outputDevices(in: [microphone, speakers]), [speakers])
    }

    /// Catches a regression where a device without a writable volume control looks usable.
    func testOutputWithoutMasterVolumeExplainsWhyTheControlIsDisabled() {
        let state = AudioDeviceState(
            devices: [],
            defaultInputID: nil,
            defaultOutputID: 2,
            outputVolume: nil,
            outputMuted: nil,
            outputControlMessage: "HDMI Display does not expose a master volume control."
        )

        XCTAssertEqual(state.outputControlMessage,
                       "HDMI Display does not expose a master volume control.")
    }
}

@MainActor
final class AudioDeviceServiceTests: XCTestCase {
    /// Catches a regression where selecting an output only changes an optimistic UI value.
    func testSelectingOutputPublishesTheStateReadBackFromHardware() {
        let speakers = AudioDevice(id: 2, name: "MacBook Speakers", directions: [.output],
                                   supportsVolume: true, supportsMute: true)
        let headphones = AudioDevice(id: 9, name: "Studio Headphones", directions: [.output],
                                     supportsVolume: true, supportsMute: true)
        let hardware = FakeAudioHardware(state: AudioDeviceState(
            devices: [speakers, headphones], defaultInputID: nil, defaultOutputID: 2,
            outputVolume: 0.8, outputMuted: false, outputControlMessage: nil
        ))
        let service = AudioDeviceService(hardware: hardware)

        service.selectDefaultDevice(9, direction: .output)

        XCTAssertEqual(service.state.defaultOutputID, 9)
        XCTAssertNil(service.errorMessage)
    }

    /// Catches a regression where a failed volume write updates the slider despite device refusal.
    func testUnsupportedVolumeKeepsLastReadValueAndShowsTheDeviceReason() {
        let hardware = FakeAudioHardware(
            state: AudioDeviceState(devices: [], defaultInputID: nil, defaultOutputID: 2,
                                    outputVolume: 0.8, outputMuted: false,
                                    outputControlMessage: nil),
            writeError: .unsupportedControl("HDMI Display does not expose a master volume control.")
        )
        let service = AudioDeviceService(hardware: hardware)

        service.setOutputVolume(0.25)

        XCTAssertEqual(service.state.outputVolume, 0.8)
        XCTAssertEqual(service.errorMessage,
                       "HDMI Display does not expose a master volume control.")
    }

    /// Keeps the tab in sync when the user changes devices in System Settings.
    func testObservedHardwareChangeRefreshesThePublishedState() {
        let speakers = AudioDevice(id: 2, name: "MacBook Speakers", directions: [.output],
                                   supportsVolume: true, supportsMute: true)
        let headphones = AudioDevice(id: 9, name: "Studio Headphones", directions: [.output],
                                     supportsVolume: true, supportsMute: true)
        let hardware = FakeAudioHardware(state: AudioDeviceState(
            devices: [speakers, headphones], defaultInputID: nil, defaultOutputID: 2,
            outputVolume: 0.8, outputMuted: false, outputControlMessage: nil
        ))
        let service = AudioDeviceService(hardware: hardware)
        let refreshed = expectation(description: "state refreshed after a hardware observation")
        hardware.onRead = { if hardware.readCount == 2 { refreshed.fulfill() } }

        hardware.state.defaultOutputID = 9
        hardware.emitObservedChange(.devices)

        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(service.state.defaultOutputID, 9)
    }

    /// Catches issue #6: volume keys and Control Center changes left the slider
    /// and mute toggle stale.
    func testObservedOutputControlChangeUpdatesVolumeAndMuteWithoutReenumerating() {
        let hardware = FakeAudioHardware(state: Self.speakersState(volume: 0.8, muted: false))
        let service = AudioDeviceService(hardware: hardware)
        let updated = expectation(description: "controls read after an outside change")
        hardware.onControlsRead = { updated.fulfill() }

        hardware.state.outputVolume = 0.35
        hardware.state.outputMuted = true
        hardware.emitObservedChange(.outputControls)

        wait(for: [updated], timeout: 1)
        XCTAssertEqual(service.state.outputVolume, 0.35)
        XCTAssertEqual(service.state.outputMuted, true)
        XCTAssertEqual(hardware.readCount, 1, "a control change must not re-enumerate devices")
    }

    /// Catches a regression where every slider tick re-enumerated all devices.
    func testVolumeAndMuteWritesReadBackOnlyTheOutputControls() {
        let hardware = FakeAudioHardware(state: Self.speakersState(volume: 0.8, muted: false))
        let service = AudioDeviceService(hardware: hardware)

        service.setOutputVolume(0.3)
        service.setOutputVolume(0.4)
        service.setOutputMuted(true)

        XCTAssertEqual(service.state.outputVolume, 0.4)
        XCTAssertEqual(service.state.outputMuted, true)
        XCTAssertEqual(hardware.readCount, 1)
        XCTAssertEqual(hardware.controlsReadCount, 3)
        XCTAssertEqual(hardware.controlsReadDeviceIDs, [2, 2, 2])
    }

    /// Catches a regression where a transient read failure stayed on screen forever.
    func testSuccessfulRefreshClearsAnEarlierReadError() {
        let hardware = FakeAudioHardware(state: Self.speakersState(volume: 0.8, muted: false))
        hardware.readError = .osStatus(-1)
        let service = AudioDeviceService(hardware: hardware)
        XCTAssertNotNil(service.errorMessage)

        hardware.readError = nil
        service.refresh()

        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(service.state.defaultOutputID, 2)
    }

    /// The read-back after a refused write must not hide why the write failed.
    func testFailedWriteKeepsItsErrorAfterTheReadBack() {
        let hardware = FakeAudioHardware(
            state: Self.speakersState(volume: 0.8, muted: false),
            writeError: .unwritableControl("The selected device does not allow this audio control to change.")
        )
        let service = AudioDeviceService(hardware: hardware)

        service.setOutputMuted(true)

        XCTAssertEqual(service.errorMessage,
                       "The selected device does not allow this audio control to change.")
        XCTAssertEqual(service.state.outputMuted, false)
    }

    /// An outside change after a refused write shows the device's real state again.
    func testObservedChangeAfterAFailedWriteClearsTheError() {
        let hardware = FakeAudioHardware(
            state: Self.speakersState(volume: 0.8, muted: false),
            writeError: .unsupportedControl("No mute here.")
        )
        let service = AudioDeviceService(hardware: hardware)
        service.setOutputMuted(true)
        XCTAssertEqual(service.errorMessage, "No mute here.")
        let updated = expectation(description: "controls read after an outside change")
        hardware.onControlsRead = { updated.fulfill() }

        hardware.state.outputVolume = 0.5
        hardware.emitObservedChange(.outputControls)

        wait(for: [updated], timeout: 1)
        XCTAssertEqual(service.state.outputVolume, 0.5)
        XCTAssertNil(service.errorMessage)
    }

    private static func speakersState(volume: Float, muted: Bool) -> AudioDeviceState {
        let speakers = AudioDevice(id: 2, name: "MacBook Speakers", directions: [.output],
                                   supportsVolume: true, supportsMute: true)
        return AudioDeviceState(devices: [speakers], defaultInputID: nil, defaultOutputID: 2,
                                outputVolume: volume, outputMuted: muted, outputControlMessage: nil)
    }
}

private final class FakeAudioHardware: AudioHardwareClient {
    var state: AudioDeviceState
    let writeError: AudioControlError?
    var readError: AudioControlError?
    var onRead: (() -> Void)?
    var onControlsRead: (() -> Void)?
    private(set) var readCount = 0
    private(set) var controlsReadCount = 0
    private(set) var controlsReadDeviceIDs: [AudioObjectID] = []
    private var observationHandler: ((AudioHardwareChange) -> Void)?

    init(state: AudioDeviceState, writeError: AudioControlError? = nil) {
        self.state = state
        self.writeError = writeError
    }

    func readDeviceState() throws -> AudioDeviceState {
        readCount += 1
        onRead?()
        if let readError { throw readError }
        return state
    }

    func readOutputControls(deviceID: AudioObjectID) throws -> AudioOutputControls {
        controlsReadCount += 1
        controlsReadDeviceIDs.append(deviceID)
        onControlsRead?()
        if let readError { throw readError }
        return state.outputControls
    }

    func emitObservedChange(_ change: AudioHardwareChange) { observationHandler?(change) }

    func setDefaultDevice(_ id: AudioObjectID, direction: AudioDirection) throws {
        if let writeError { throw writeError }
        switch direction {
        case .input: state.defaultInputID = id
        case .output: state.defaultOutputID = id
        }
    }

    func setOutputVolume(_ value: Float, deviceID: AudioObjectID) throws {
        if let writeError { throw writeError }
        state.outputVolume = value
    }

    func setOutputMuted(_ muted: Bool, deviceID: AudioObjectID) throws {
        if let writeError { throw writeError }
        state.outputMuted = muted
    }

    func startObserving(_ handler: @escaping (AudioHardwareChange) -> Void) { observationHandler = handler }
    func stopObserving() { observationHandler = nil }
}
