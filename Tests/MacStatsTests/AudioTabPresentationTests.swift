import XCTest
@testable import MacStats

final class AudioTabPresentationTests: XCTestCase {
    private let speakers = AudioDevice(id: 2, name: "Speakers", directions: [.output], supportsVolume: true, supportsMute: true)

    func testPercentTextRoundsAndClamps() {
        XCTAssertEqual(AudioTabPresentation.percentText(0.8), "80 percent")
        XCTAssertEqual(AudioTabPresentation.percentText(0.333), "33 percent")
        XCTAssertEqual(AudioTabPresentation.percentText(0.005), "1 percent")
        XCTAssertEqual(AudioTabPresentation.percentText(-0.2), "0 percent")
        XCTAssertEqual(AudioTabPresentation.percentText(1.4), "100 percent")
    }

    func testVolumeValueMentionsMuteAndUnavailableControls() {
        XCTAssertEqual(AudioTabPresentation.volumeValue(level: 0.8, muted: false), "80 percent")
        XCTAssertEqual(AudioTabPresentation.volumeValue(level: 0.8, muted: nil), "80 percent")
        XCTAssertEqual(AudioTabPresentation.volumeValue(level: 0.5, muted: true), "Muted, 50 percent")
        XCTAssertEqual(AudioTabPresentation.volumeValue(level: nil, muted: true), "Unavailable")
    }

    func testPerAppLabelsIncludeTheAppName() {
        XCTAssertEqual(AudioTabPresentation.volumeLabel(for: "Safari"), "Safari volume")
        XCTAssertEqual(AudioTabPresentation.muteLabel(for: "Safari"), "Mute Safari")
        XCTAssertNotEqual(AudioTabPresentation.muteLabel(for: "Music"), AudioTabPresentation.muteLabel(for: "Safari"))
    }

    func testEmptyDeviceListShowsEmptyState() {
        XCTAssertEqual(AudioTabPresentation.deviceContent(for: .empty), .empty)

        var state = AudioDeviceState.empty
        state.devices = [speakers]
        state.defaultOutputID = speakers.id
        XCTAssertEqual(AudioTabPresentation.deviceContent(for: state), .devices)
    }

    func testProcessStatusReflectsMuteThenGain() {
        let playing = AppMixerProcess(id: 1, processID: 10, name: "Music", gain: 0.6, muted: false)
        var silent = playing
        silent.gain = 0
        var muted = playing
        muted.muted = true

        XCTAssertEqual(AudioTabPresentation.status(for: playing).text, "Mixing")
        XCTAssertEqual(AudioTabPresentation.status(for: silent).text, "Silent")
        XCTAssertEqual(AudioTabPresentation.status(for: muted).text, "Muted")
        XCTAssertEqual(AudioTabPresentation.status(for: muted).systemImage, "speaker.slash.fill")
    }
}
