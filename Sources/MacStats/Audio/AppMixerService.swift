import Combine
import CoreAudio
import Foundation

enum AppMixerCapability: Equatable, Sendable {
    case available
    case requiresMacOS142
}

enum AppMixerPermission: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

struct AppMixerProcess: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let processID: pid_t
    let name: String
    var gain: Float
    var muted: Bool
}

enum AppMixerError: Error, Equatable {
    case unavailable(String)

    var message: String {
        switch self {
        case let .unavailable(message): return message
        }
    }
}

protocol AppMixerPlatform: AnyObject {
    var capability: AppMixerCapability { get }
    var permission: AppMixerPermission { get }
    func requestPermission() async -> AppMixerPermission
    func start() throws
    func stop()
    func setGain(_ gain: Float, for processID: pid_t)
    func setMuted(_ muted: Bool, for processID: pid_t)
    var processes: [AppMixerProcess] { get }
}

extension AppMixerPlatform {
    func setGain(_ gain: Float, for processID: pid_t) {}
    func setMuted(_ muted: Bool, for processID: pid_t) {}
    var processes: [AppMixerProcess] { [] }
}

final class AppMixerService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var processes: [AppMixerProcess] = []

    var capability: AppMixerCapability { platform.capability }

    private let platform: AppMixerPlatform

    init(platform: AppMixerPlatform = SystemAppMixerPlatform()) {
        self.platform = platform
        statusMessage = platform.capability == .requiresMacOS142
            ? "Application mixing requires macOS 14.2 or later."
            : nil
    }

    func enable() async {
        guard platform.capability == .available else {
            statusMessage = "Application mixing requires macOS 14.2 or later."
            return
        }

        let permission: AppMixerPermission
        switch platform.permission {
        case .authorized:
            permission = .authorized
        case .notDetermined:
            permission = await platform.requestPermission()
        case .denied:
            permission = .denied
        }

        guard permission == .authorized else {
            statusMessage = "MacStats does not have permission to capture application audio."
            return
        }

        do {
            try platform.start()
            isRunning = true
            processes = platform.processes
            statusMessage = nil
        } catch let error as AppMixerError {
            statusMessage = error.message
        } catch {
            statusMessage = "MacStats could not start the application mixer."
        }
    }

    func disable() {
        platform.stop()
        isRunning = false
        processes = []
    }

    func setGain(_ gain: Float, for processID: pid_t) {
        let clamped = min(max(gain, 0), 1)
        platform.setGain(clamped, for: processID)
        processes = processes.map { process in
            guard process.processID == processID else { return process }
            var updated = process
            updated.gain = clamped
            return updated
        }
    }

    func setMuted(_ muted: Bool, for processID: pid_t) {
        platform.setMuted(muted, for: processID)
        processes = processes.map { process in
            guard process.processID == processID else { return process }
            var updated = process
            updated.muted = muted
            return updated
        }
    }
}

private final class SystemAppMixerPlatform: AppMixerPlatform {
    private var session: AnyObject?

    var processes: [AppMixerProcess] {
        if #available(macOS 14.2, *) { return (session as? AppMixerSession)?.processes ?? [] }
        return []
    }
    var capability: AppMixerCapability {
        if #available(macOS 14.2, *) { return .available }
        return .requiresMacOS142
    }

    var permission: AppMixerPermission {
        // System-audio capture permission is granted by Core Audio when the
        // aggregate device starts. There is no microphone-permission API that
        // can answer this state accurately before that point.
        return .notDetermined
    }

    func requestPermission() async -> AppMixerPermission {
        // The first aggregate-device start triggers macOS's system-audio
        // capture prompt. Keep this method side-effect free until then.
        .authorized
    }

    func start() throws {
        guard #available(macOS 14.2, *) else {
            throw AppMixerError.unavailable("Application mixing requires macOS 14.2 or later.")
        }
        session = try AppMixerSession()
    }

    func stop() {
        if #available(macOS 14.2, *) {
            (session as? AppMixerSession)?.stop()
        }
        session = nil
    }

    func setGain(_ gain: Float, for processID: pid_t) {
        if #available(macOS 14.2, *) { (session as? AppMixerSession)?.setGain(gain, for: processID) }
    }

    func setMuted(_ muted: Bool, for processID: pid_t) {
        if #available(macOS 14.2, *) { (session as? AppMixerSession)?.setMuted(muted, for: processID) }
    }
}
