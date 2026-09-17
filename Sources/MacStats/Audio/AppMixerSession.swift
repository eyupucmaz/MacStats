import Cocoa
import CoreAudio
import Foundation

private struct AppMixerRealtimeControl {
    var gain: Float
    var muted: UInt32
}

@available(macOS 14.2, *)
final class AppMixerSession {
    private let originalOutputID: AudioObjectID
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private let controls: UnsafeMutablePointer<AppMixerRealtimeControl>
    let processes: [AppMixerProcess]

    init() throws {
        originalOutputID = try Self.defaultOutputID()
        let discovered = try Self.discoverProcesses()
        guard !discovered.isEmpty else { throw AppMixerError.unavailable("No audible application is currently available to mix.") }
        processes = discovered.map { AppMixerProcess(id: $0.id, processID: $0.pid, name: $0.name, gain: 1, muted: false) }
        controls = .allocate(capacity: discovered.count)
        controls.initialize(repeating: AppMixerRealtimeControl(gain: 1, muted: 0), count: discovered.count)

        do {
            let outputUID = try Self.uid(of: originalOutputID, selector: kAudioDevicePropertyDeviceUID)
            var tapUIDs: [String] = []
            for process in discovered {
                let description = CATapDescription(processes: [process.id], deviceUID: outputUID, stream: 0)
                description.name = "MacStats App Mixer \(process.pid)"
                description.isPrivate = true
                description.isMixdown = true
                description.isMono = false
                description.muteBehavior = .muted
                var tapID = AudioObjectID(kAudioObjectUnknown)
                guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { throw AppMixerError.unavailable("MacStats could not create an application audio tap.") }
                tapIDs.append(tapID)
                tapUIDs.append(try Self.uid(of: tapID, selector: kAudioTapPropertyUID))
            }
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: "MacStats App Mixer",
                kAudioAggregateDeviceUIDKey as String: "com.eyupucmaz.MacStats.AppMixer.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceTapAutoStartKey as String: true,
                kAudioAggregateDeviceTapListKey as String: tapUIDs.map { [kAudioSubTapUIDKey as String: $0, kAudioSubTapDriftCompensationKey as String: true] }
            ]
            guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr else { throw AppMixerError.unavailable("MacStats could not create the application mixer output.") }
            let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inputData, _, outputData, _ in
                self?.render(inputData: inputData, outputData: outputData)
            }
            guard status == noErr, let ioProcID else { throw AppMixerError.unavailable("MacStats could not prepare the application mixer stream.") }
            try Self.setDefaultOutputID(aggregateID)
            guard AudioDeviceStart(aggregateID, ioProcID) == noErr else { throw AppMixerError.unavailable("MacStats could not start the application mixer stream.") }
            started = true
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop(); controls.deinitialize(count: processes.count); controls.deallocate() }

    func stop() {
        if started, let ioProcID { AudioDeviceStop(aggregateID, ioProcID) }
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        try? Self.setDefaultOutputID(originalOutputID)
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        for tapID in tapIDs { AudioHardwareDestroyProcessTap(tapID) }
        tapIDs.removeAll(); aggregateID = kAudioObjectUnknown; ioProcID = nil; started = false
    }

    func setGain(_ gain: Float, for processID: pid_t) {
        guard let index = processes.firstIndex(where: { $0.processID == processID }) else { return }
        controls[index].gain = gain
    }

    func setMuted(_ muted: Bool, for processID: pid_t) {
        guard let index = processes.firstIndex(where: { $0.processID == processID }) else { return }
        controls[index].muted = muted ? 1 : 0
    }

    private func render(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        for (index, pair) in zip(input, output).enumerated() {
            guard let source = pair.0.mData, let destination = pair.1.mData else { continue }
            let count = min(Int(pair.0.mDataByteSize), Int(pair.1.mDataByteSize)) / MemoryLayout<Float>.size
            let sourceSamples = source.assumingMemoryBound(to: Float.self)
            let destinationSamples = destination.assumingMemoryBound(to: Float.self)
            let control = controls[min(index, processes.count - 1)]
            for sample in 0..<count { destinationSamples[sample] = control.muted == 0 ? sourceSamples[sample] * control.gain : 0 }
        }
    }

    private static func discoverProcesses() throws -> [(id: AudioObjectID, pid: pid_t, name: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0; var propertySize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &propertySize, &pid) == noErr, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0; propertySize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &propertySize, &running) == noErr, running != 0 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return (id, pid, app?.localizedName ?? app?.bundleIdentifier ?? "Process \(pid)")
        }
    }

    private static func defaultOutputID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { throw AppMixerError.unavailable("No output device is currently available.") }
        return id
    }

    private static func setDefaultOutputID(_ id: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = id
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr else { throw AppMixerError.unavailable("MacStats could not change the default output device.") }
    }

    private static func uid(of id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { throw AppMixerError.unavailable("MacStats could not identify the audio tap.") }
        return value.takeRetainedValue() as String
    }
}
