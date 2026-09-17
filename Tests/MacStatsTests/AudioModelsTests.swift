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
        hardware.emitObservedChange()

        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(service.state.defaultOutputID, 9)
    }

}

private final class FakeAudioHardware: AudioHardwareClient {
    var state: AudioDeviceState
    let writeError: AudioControlError?
    var onRead: (() -> Void)?
    private(set) var readCount = 0
    private var observationHandler: (() -> Void)?

    init(state: AudioDeviceState, writeError: AudioControlError? = nil) {
        self.state = state
        self.writeError = writeError
    }

    func readDeviceState() throws -> AudioDeviceState {
        readCount += 1
        onRead?()
        return state
    }

    func emitObservedChange() { observationHandler?() }

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

    func startObserving(_ handler: @escaping () -> Void) { observationHandler = handler }
    func stopObserving() { observationHandler = nil }
}
