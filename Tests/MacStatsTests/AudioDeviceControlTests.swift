import CoreAudio
import XCTest
@testable import MacStats

final class AudioDeviceControlTests: XCTestCase {
    private let deviceID: AudioObjectID = 7
    private let main = kAudioObjectPropertyElementMain
    private let volume = kAudioDevicePropertyVolumeScalar
    private let mute = kAudioDevicePropertyMute

    /// Built-in outputs keep using the main element.
    func testMainElementIsPreferredWhenSettable() throws {
        let properties = FakeAudioProperties()
        properties.set(volume, element: main, to: .float(0.6), settable: true)
        properties.set(volume, element: 1, to: .float(0.2), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        XCTAssertEqual(driver.elements(for: volume, deviceID: deviceID),
                       AudioOutputControlElements(elements: [main], isSettable: true))
        XCTAssertEqual(try driver.readVolume(deviceID: deviceID), 0.6)
    }

    /// Catches issue #6: USB/Bluetooth devices with per-channel volume were
    /// reported as having no volume control.
    func testVolumeFallsBackToStereoChannelsWithoutAMainControl() throws {
        let properties = FakeAudioProperties()
        properties.set(volume, element: 1, to: .float(0.4), settable: true)
        properties.set(volume, element: 2, to: .float(0.8), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        XCTAssertEqual(driver.elements(for: volume, deviceID: deviceID),
                       AudioOutputControlElements(elements: [1, 2], isSettable: true))
        XCTAssertEqual(try driver.readVolume(deviceID: deviceID), 0.8)
    }

    /// A read-only main element must not hide settable channels.
    func testSettableChannelsWinOverAReadOnlyMainElement() {
        let properties = FakeAudioProperties()
        properties.set(volume, element: main, to: .float(1), settable: false)
        properties.set(volume, element: 1, to: .float(0.5), settable: true)
        properties.set(volume, element: 2, to: .float(0.5), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        XCTAssertEqual(driver.elements(for: volume, deviceID: deviceID),
                       AudioOutputControlElements(elements: [1, 2], isSettable: true))
    }

    /// The device's preferred stereo pair is used instead of channels 1/2 when reported.
    func testPreferredStereoChannelsAreUsed() throws {
        let properties = FakeAudioProperties()
        properties.stereoChannels = [3, 4]
        properties.set(volume, element: 1, to: .float(0.1), settable: true)
        properties.set(volume, element: 3, to: .float(0.7), settable: true)
        properties.set(volume, element: 4, to: .float(0.7), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        XCTAssertEqual(try driver.readVolume(deviceID: deviceID), 0.7)
        XCTAssertEqual(driver.elements(for: volume, deviceID: deviceID)?.elements, [3, 4])
    }

    /// Writing per-channel volume keeps the left/right balance.
    func testPerChannelVolumeWriteKeepsBalance() throws {
        let properties = FakeAudioProperties()
        properties.set(volume, element: 1, to: .float(0.4), settable: true)
        properties.set(volume, element: 2, to: .float(0.8), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        try driver.setVolume(0.5, deviceID: deviceID)

        XCTAssertEqual(properties.float(volume, element: 1) ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(properties.float(volume, element: 2) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try driver.readVolume(deviceID: deviceID) ?? -1, 0.5, accuracy: 0.0001)
    }

    /// Silent channels have no balance to keep, so every channel gets the new value.
    func testPerChannelVolumeWriteFromSilenceSetsEveryChannel() throws {
        let properties = FakeAudioProperties()
        properties.set(volume, element: 1, to: .float(0), settable: true)
        properties.set(volume, element: 2, to: .float(0), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        try driver.setVolume(0.6, deviceID: deviceID)

        XCTAssertEqual(properties.float(volume, element: 1), 0.6)
        XCTAssertEqual(properties.float(volume, element: 2), 0.6)
    }

    /// Per-channel mute is written to every channel and reads muted only when all are.
    func testPerChannelMuteFallback() throws {
        let properties = FakeAudioProperties()
        properties.set(mute, element: 1, to: .flag(false), settable: true)
        properties.set(mute, element: 2, to: .flag(true), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        XCTAssertEqual(try driver.readMuted(deviceID: deviceID), false)

        try driver.setMuted(true, deviceID: deviceID)

        XCTAssertEqual(properties.flag(mute, element: 1), true)
        XCTAssertEqual(properties.flag(mute, element: 2), true)
        XCTAssertEqual(try driver.readMuted(deviceID: deviceID), true)
    }

    /// Read-only controls are still shown but refuse writes with a clear reason.
    func testReadOnlyControlIsReadableButNotWritable() throws {
        let properties = FakeAudioProperties()
        properties.set(volume, element: main, to: .float(0.9), settable: false)
        let driver = AudioOutputControlDriver(properties: properties)

        XCTAssertEqual(try driver.readVolume(deviceID: deviceID), 0.9)
        XCTAssertThrowsError(try driver.setVolume(0.2, deviceID: deviceID)) { error in
            guard case .unwritableControl = error as? AudioControlError else {
                return XCTFail("expected unwritableControl, got \(error)")
            }
        }
        XCTAssertEqual(properties.float(volume, element: main), 0.9)
    }

    /// Devices without any volume or mute show no control and explain why on write.
    func testMissingControlsReadAsNilAndRefuseWrites() throws {
        let driver = AudioOutputControlDriver(properties: FakeAudioProperties())

        XCTAssertEqual(try driver.readControls(deviceID: deviceID), AudioOutputControls(volume: nil, muted: nil))
        XCTAssertThrowsError(try driver.setMuted(true, deviceID: deviceID)) { error in
            guard case .unsupportedControl = error as? AudioControlError else {
                return XCTFail("expected unsupportedControl, got \(error)")
            }
        }
    }

    /// Listeners must cover the per-channel elements, or channel-only devices never update.
    func testObservableAddressesIncludeEveryExistingVolumeAndMuteElement() {
        let properties = FakeAudioProperties()
        properties.set(volume, element: 1, to: .float(0.5), settable: true)
        properties.set(volume, element: 2, to: .float(0.5), settable: true)
        properties.set(mute, element: main, to: .flag(false), settable: true)
        let driver = AudioOutputControlDriver(properties: properties)

        let observed = driver.observableAddresses(deviceID: deviceID).map { "\($0.mSelector):\($0.mElement)" }

        XCTAssertEqual(Set(observed), ["\(volume):1", "\(volume):2", "\(mute):\(main)"])
    }
}

private final class FakeAudioProperties: AudioPropertyAccess {
    enum Value: Equatable {
        case float(Float)
        case flag(Bool)
    }

    private struct Key: Hashable {
        let selector: AudioObjectPropertySelector
        let element: AudioObjectPropertyElement
    }

    var stereoChannels: [AudioObjectPropertyElement]?
    private var values: [Key: Value] = [:]
    private var settable: Set<Key> = []

    func set(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement,
             to value: Value, settable isSettable: Bool) {
        let key = Key(selector: selector, element: element)
        values[key] = value
        if isSettable { settable.insert(key) } else { settable.remove(key) }
    }

    func float(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
        guard case let .float(value) = values[Key(selector: selector, element: element)] else { return nil }
        return value
    }

    func flag(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool? {
        guard case let .flag(value) = values[Key(selector: selector, element: element)] else { return nil }
        return value
    }

    func hasProperty(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) -> Bool {
        values[key(address)] != nil
    }

    func isSettable(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) -> Bool {
        settable.contains(key(address))
    }

    func readFloat(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws -> Float {
        guard case let .float(value) = values[key(address)] else { throw AudioControlError.osStatus(-1) }
        return value
    }

    func readFlag(_ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws -> Bool {
        guard case let .flag(value) = values[key(address)] else { throw AudioControlError.osStatus(-1) }
        return value
    }

    func writeFloat(_ value: Float, _ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws {
        guard settable.contains(key(address)) else { throw AudioControlError.osStatus(-1) }
        values[key(address)] = .float(value)
    }

    func writeFlag(_ value: Bool, _ address: AudioObjectPropertyAddress, objectID: AudioObjectID) throws {
        guard settable.contains(key(address)) else { throw AudioControlError.osStatus(-1) }
        values[key(address)] = .flag(value)
    }

    func preferredStereoChannels(objectID: AudioObjectID) -> [AudioObjectPropertyElement]? {
        stereoChannels
    }

    private func key(_ address: AudioObjectPropertyAddress) -> Key {
        XCTAssertEqual(address.mScope, kAudioDevicePropertyScopeOutput)
        return Key(selector: address.mSelector, element: address.mElement)
    }
}
