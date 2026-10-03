import Cocoa
import CoreAudio
import Foundation

/// Production `AppMixerPlatform`. All Core Audio work — discovery, session
/// build/teardown and property listeners — runs on one private serial queue,
/// so a session is never built and torn down concurrently. `@unchecked
/// Sendable` because of that confinement; `onEvent` is set once on the main
/// actor before any event can fire.
final class SystemAppMixerPlatform: AppMixerPlatform, @unchecked Sendable {
    var onEvent: (@MainActor (AppMixerEvent) -> Void)?

    private let queue = DispatchQueue(label: "com.eyupucmaz.MacStats.AppMixer", qos: .userInitiated)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var workspaceObservers: [NSObjectProtocol] = []

    // Queue-confined state.
    private var session: AnyObject?
    private var sessionOutputID = AudioObjectID(kAudioObjectUnknown)
    private var tappedPIDs: Set<pid_t> = []
    private var isObserving = false
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var outputAliveListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    private var pendingEvaluation: DispatchWorkItem?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.emit(.willSleep) },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.emit(.didWake) }
        ]
    }

    deinit {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        stop()
    }

    var capability: AppMixerCapability {
        if #available(macOS 14.2, *) { return .available }
        return .requiresMacOS142
    }

    var permission: AppMixerPermission { AppMixerCapturePermission.current }

    func requestPermission() async -> AppMixerPermission {
        await AppMixerCapturePermission.request()
    }

    func start(retaining: [AppMixerProcess]) async throws -> [AppMixerProcess] {
        guard #available(macOS 14.2, *) else { throw AppMixerError.unavailable(AppMixerService.unsupportedMessage) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try buildSession(retaining: retaining))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            tearDownSession()
            removeListeners()
        }
    }

    func apply(_ process: AppMixerProcess) {
        queue.async { [self] in
            if #available(macOS 14.2, *) { (session as? AppMixerSession)?.apply(process) }
        }
    }

    // MARK: - Session (queue)

    /// The old session is torn down before the new one starts, so a rebuild
    /// lets tapped apps play unadjusted for a moment; running both would play
    /// them twice.
    @available(macOS 14.2, *)
    private func buildSession(retaining: [AppMixerProcess]) throws -> [AppMixerProcess] {
        installListeners()
        tearDownSession()

        let settings = Dictionary(retaining.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
        let processes = discoverProcesses()
            .filter { $0.isAudible || settings[$0.pid] != nil }
            .map { candidate in
                AppMixerProcess(
                    id: candidate.id,
                    processID: candidate.pid,
                    name: candidate.name,
                    gain: settings[candidate.pid]?.gain ?? 1,
                    muted: settings[candidate.pid]?.muted ?? false
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // With nothing audible there is nothing to tap; keep listening and
        // build a session once an app starts playing.
        guard !processes.isEmpty else { return [] }
        guard let outputID = AppMixerCoreAudio.defaultOutputID() else {
            throw AppMixerError.unavailable(AudioControlError.deviceUnavailable.message)
        }
        session = try AppMixerSession(outputDeviceID: outputID, processes: processes)
        sessionOutputID = outputID
        tappedPIDs = Set(processes.map(\.processID))
        observeOutputDevice(outputID)
        return processes
    }

    private func tearDownSession() {
        if #available(macOS 14.2, *) { (session as? AppMixerSession)?.stop() }
        session = nil
        sessionOutputID = AudioObjectID(kAudioObjectUnknown)
        tappedPIDs = []
        if let (deviceID, block) = outputAliveListener {
            var address = AppMixerCoreAudio.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
            outputAliveListener = nil
        }
    }

    // MARK: - Discovery (queue)

    private struct Candidate {
        let id: AudioObjectID
        let pid: pid_t
        let name: String
        let isAudible: Bool
    }

    private func discoverProcesses() -> [Candidate] {
        AppMixerCoreAudio.objectIDs(of: AppMixerCoreAudio.system, selector: kAudioHardwarePropertyProcessObjectList).compactMap { id in
            var address = AppMixerCoreAudio.address(kAudioProcessPropertyPID)
            var pid: pid_t = 0; var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr, pid > 0, pid != ownPID else { return nil }
            let audible = (AppMixerCoreAudio.uint32(of: id, selector: kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = try? AppMixerCoreAudio.string(of: id, selector: kAudioProcessPropertyBundleID)
            let name = app?.localizedName ?? app?.bundleIdentifier ?? bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("Process \(String(pid))")
            return Candidate(id: id, pid: pid, name: name, isAudible: audible)
        }
    }

    /// Debounced: a burst of process events (an app launching helpers, a
    /// browser starting several streams) becomes one rebuild request.
    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluateProcesses() }
        pendingEvaluation = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Requests a rebuild only when the set worth tapping — audible apps plus
    /// already-tapped apps that are still alive — differs from the session's.
    /// A paused app keeps its tap and settings; an exited app loses them.
    private func evaluateProcesses() {
        guard isObserving else { return }
        syncProcessListeners(AppMixerCoreAudio.objectIDs(of: AppMixerCoreAudio.system, selector: kAudioHardwarePropertyProcessObjectList))
        let candidates = discoverProcesses()
        let alive = Set(candidates.map(\.pid))
        let audible = Set(candidates.filter(\.isAudible).map(\.pid))
        let desired = audible.union(tappedPIDs.intersection(alive))
        if desired != tappedPIDs { emit(.processesChanged) }
    }

    // MARK: - Listeners (queue)

    private func installListeners() {
        guard !isObserving else { return }
        isObserving = true
        addSystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleEvaluation() }
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.defaultOutputChanged() }
        addSystemListener(kAudioHardwarePropertyServiceRestarted) { [weak self] in
            self?.emit(.interrupted(L10n.string("App Mixer stopped because the macOS audio service restarted.")))
        }
        syncProcessListeners(AppMixerCoreAudio.objectIDs(of: AppMixerCoreAudio.system, selector: kAudioHardwarePropertyProcessObjectList))
    }

    private func removeListeners() {
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AppMixerCoreAudio.system, &address, queue, block)
        }
        systemListeners.removeAll()
        syncProcessListeners([])
        isObserving = false
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = AppMixerCoreAudio.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(AppMixerCoreAudio.system, &address, queue, block) == noErr {
            systemListeners.append((address, block))
        }
    }

    /// Keeps one "is running output" listener per Core Audio process object,
    /// so an already-connected app that starts playing is noticed.
    private func syncProcessListeners(_ ids: [AudioObjectID]) {
        let wanted = Set(ids)
        for (id, block) in processListeners where !wanted.contains(id) {
            var address = AppMixerCoreAudio.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
            processListeners[id] = nil
        }
        for id in wanted where processListeners[id] == nil {
            var address = AppMixerCoreAudio.address(kAudioProcessPropertyIsRunningOutput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleEvaluation() }
            if AudioObjectAddPropertyListenerBlock(id, &address, queue, block) == noErr {
                processListeners[id] = block
            }
        }
    }

    private func observeOutputDevice(_ deviceID: AudioObjectID) {
        var address = AppMixerCoreAudio.address(kAudioDevicePropertyDeviceIsAlive)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard AppMixerCoreAudio.uint32(of: deviceID, selector: kAudioDevicePropertyDeviceIsAlive) != 1 else { return }
            self?.emit(.outputDeviceChanged)
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
            outputAliveListener = (deviceID, block)
        }
    }

    /// The session renders into the device it was built on, so it must not
    /// outlive that device being the default output. Without a session the
    /// next build simply uses the new default.
    private func defaultOutputChanged() {
        guard session != nil, AppMixerCoreAudio.defaultOutputID() != sessionOutputID else { return }
        emit(.outputDeviceChanged)
    }

    private func emit(_ event: AppMixerEvent) {
        Task { @MainActor [weak self] in self?.onEvent?(event) }
    }
}

/// System-audio capture permission (TCC service `kTCCServiceAudioCapture`).
///
/// macOS has no public API to read or request this permission; without one,
/// denial is invisible because taps simply deliver silence. MacStats uses the
/// TCC preflight/request SPI when it resolves at runtime, and otherwise falls
/// back to the prompt Core Audio shows when the first session starts.
enum AppMixerCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: Preflight? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
    private static let requestAccess: Request? = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }

    static var current: AppMixerPermission {
        guard let preflight else { return .notDetermined }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    static func request() async -> AppMixerPermission {
        guard let requestAccess else { return .authorized }
        return await withCheckedContinuation { continuation in
            requestAccess(service, nil) { granted in
                continuation.resume(returning: granted ? .authorized : .denied)
            }
        }
    }
}
