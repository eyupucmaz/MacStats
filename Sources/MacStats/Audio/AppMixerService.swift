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

/// Things that happen to a running mixer outside the user's control.
enum AppMixerEvent: Equatable, Sendable {
    /// An app started playing or a tapped app exited; the session needs new taps.
    case processesChanged
    /// The default output changed or the session's output device went away.
    case outputDeviceChanged
    /// Core Audio invalidated the session (for example, coreaudiod restarted).
    case interrupted(String)
    case willSleep
    case didWake
}

/// Core Audio facade for `AppMixerService`. Implementations do their Core
/// Audio work off the main thread and deliver `onEvent` on the main actor.
protocol AppMixerPlatform: AnyObject, Sendable {
    var capability: AppMixerCapability { get }
    /// The current capture permission, without prompting.
    var permission: AppMixerPermission { get }
    var onEvent: (@MainActor (AppMixerEvent) -> Void)? { get set }
    func requestPermission() async -> AppMixerPermission
    /// Builds a session on the current default output, replacing any running
    /// one. Taps every audible app plus the `retaining` apps that are still
    /// alive, applying their gain and mute. Returns the tapped apps.
    func start(retaining: [AppMixerProcess]) async throws -> [AppMixerProcess]
    /// Synchronously tears down every tap and aggregate device. Idempotent.
    func stop()
    func apply(_ process: AppMixerProcess)
}

/// Owns the app mixer's user-facing state.
///
/// Lifecycle: the mixer runs from an explicit Enable until Disable, quit, an
/// output-device change, loss of permission or a Core Audio failure. It keeps
/// running when the popover or Audio tab closes — a per-app volume that resets
/// whenever the transient popover dismisses would be useless — and pauses
/// across sleep, resuming on wake. Nothing about it is persisted.
@MainActor
final class AppMixerService: ObservableObject {
    enum Phase: Equatable {
        case off
        case requestingPermission
        case starting
        case running
    }

    nonisolated static let unsupportedMessage = "Application mixing requires macOS 14.2 or later."
    nonisolated static let deniedMessage = "MacStats does not have permission to capture application audio."
    nonisolated static let revokedMessage = "App Mixer stopped because audio capture permission was turned off."
    nonisolated static let outputChangedMessage = "App Mixer stopped because the output device changed. Enable it again to mix on the new device."
    nonisolated static let startFailedMessage = "MacStats could not start the application mixer."
    /// Privacy & Security → Screen & System Audio Recording, where system-audio
    /// capture is granted or revoked.
    nonisolated static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    @Published private(set) var phase: Phase = .off
    @Published private(set) var permission: AppMixerPermission = .notDetermined
    @Published private(set) var statusMessage: String?
    @Published private(set) var processes: [AppMixerProcess] = []

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { phase == .requestingPermission || phase == .starting }
    var capability: AppMixerCapability { platform.capability }

    private let platform: AppMixerPlatform
    /// Bumped by every stop so continuations of an abandoned enable or
    /// rebuild can tell that they are stale.
    private var generation = 0
    private var rebuildInFlight = false
    private var rebuildPending = false
    private var resumesAfterWake = false

    /// Nonisolated so `AppDelegate` can create it as a stored property. The
    /// permission is read on the main actor by `refreshPermission()`.
    nonisolated init(platform: AppMixerPlatform = SystemAppMixerPlatform()) {
        self.platform = platform
        platform.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Idempotent: does nothing while a session is starting or running.
    func enable() async {
        guard phase == .off else { return }
        guard platform.capability == .available else {
            statusMessage = Self.unsupportedMessage
            return
        }
        generation += 1
        let current = generation
        statusMessage = nil
        phase = .requestingPermission

        var granted = platform.permission
        if granted == .notDetermined {
            granted = await platform.requestPermission()
        }
        guard current == generation else { return }
        permission = granted
        guard granted == .authorized else {
            phase = .off
            statusMessage = Self.deniedMessage
            return
        }

        phase = .starting
        do {
            let started = try await platform.start(retaining: [])
            guard current == generation else { return }
            processes = started
            phase = .running
        } catch {
            guard current == generation else { return }
            stop(message: Self.message(for: error))
        }
    }

    /// Nonisolated only so the (nonisolated) `AppDelegate` termination path
    /// can call it; it must still be called on the main thread.
    nonisolated func disable() {
        MainActor.assumeIsolated {
            resumesAfterWake = false
            stop(message: nil)
        }
    }

    /// Re-reads the capture permission (e.g. when the Audio tab appears) and
    /// stops the mixer if it was revoked in System Settings.
    func refreshPermission() {
        guard platform.capability == .available else { return }
        permission = platform.permission
        if permission == .denied, phase != .off {
            resumesAfterWake = false
            stop(message: Self.revokedMessage)
        }
    }

    func setGain(_ gain: Float, for processID: pid_t) {
        update(processID) { $0.gain = min(max(gain, 0), 1) }
    }

    func setMuted(_ muted: Bool, for processID: pid_t) {
        update(processID) { $0.muted = muted }
    }

    // MARK: - Private

    private func update(_ processID: pid_t, _ change: (inout AppMixerProcess) -> Void) {
        guard let index = processes.firstIndex(where: { $0.processID == processID }) else { return }
        change(&processes[index])
        platform.apply(processes[index])
    }

    private func stop(message: String?) {
        generation += 1
        if phase != .off { platform.stop() }
        phase = .off
        processes = []
        rebuildInFlight = false
        rebuildPending = false
        statusMessage = message
    }

    private func handle(_ event: AppMixerEvent) {
        switch event {
        case .processesChanged:
            Task { await rebuild() }
        case .outputDeviceChanged:
            guard phase != .off else { return }
            resumesAfterWake = false
            stop(message: Self.outputChangedMessage)
        case let .interrupted(message):
            guard phase != .off else { return }
            resumesAfterWake = false
            stop(message: message)
        case .willSleep:
            guard phase != .off else { return }
            stop(message: nil)
            resumesAfterWake = true
        case .didWake:
            guard resumesAfterWake else { return }
            resumesAfterWake = false
            Task { await enable() }
        }
    }

    /// Re-taps the current set of apps, coalescing bursts of change events
    /// into at most one rebuild in flight plus one queued.
    private func rebuild() async {
        guard phase == .running else { return }
        guard !rebuildInFlight else {
            rebuildPending = true
            return
        }
        refreshPermission()
        guard phase == .running else { return }

        rebuildInFlight = true
        let current = generation
        do {
            let rebuilt = try await platform.start(retaining: processes)
            guard current == generation else { return }
            // Gain/mute changes made while rebuilding were already forwarded to
            // the new session; keep them rather than the pre-rebuild snapshot.
            let latest = Dictionary(processes.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
            processes = rebuilt.map { process in
                guard let known = latest[process.processID] else { return process }
                var merged = process
                merged.gain = known.gain
                merged.muted = known.muted
                return merged
            }
        } catch {
            guard current == generation else { return }
            stop(message: Self.message(for: error))
            return
        }
        rebuildInFlight = false
        if rebuildPending {
            rebuildPending = false
            await rebuild()
        }
    }

    private static func message(for error: Error) -> String {
        (error as? AppMixerError)?.message ?? startFailedMessage
    }
}
