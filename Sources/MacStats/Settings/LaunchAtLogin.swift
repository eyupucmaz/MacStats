import Foundation
import ServiceManagement

/// The login-item calls `LaunchAtLogin` makes. Kept behind a protocol so every
/// registration state can be exercised without a `.app` bundle or launchd.
protocol LoginItemService {
    /// False when not running from a `.app` bundle (e.g. `swift run` / `./.build/debug/MacStats`).
    var isSupported: Bool { get }
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Production `LoginItemService`: `SMAppService.mainApp`. Only functional when the
/// executable runs from a real `.app` bundle — a bare SPM binary has no
/// launchd-registerable app record.
struct MainAppLoginItem: LoginItemService {
    /// `SMAppService` silently no-ops (or throws) outside a bundle, so gate on it.
    var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws { try SMAppService.mainApp.register() }

    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Launch-at-Login state and changes for the settings UI, over a `LoginItemService`.
struct LaunchAtLogin {
    enum Failure: LocalizedError {
        /// Not running from a `.app` bundle (e.g. `swift run` / `./.build/debug/MacStats`).
        case unsupported
        case system(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return L10n.string("Launch at Login only works when MacStats is installed as an app, not in a development build.")
            case .system(let message):
                return L10n.string("Couldn't change Launch at Login: \(message)")
            }
        }
    }

    let service: LoginItemService

    init(service: LoginItemService = MainAppLoginItem()) {
        self.service = service
    }

    var isSupported: Bool { service.isSupported }

    var isEnabled: Bool {
        guard isSupported else { return false }
        return service.status == .enabled
    }

    /// Human-readable state for the settings UI.
    var statusDescription: String {
        guard isSupported else {
            return L10n.string("Not available in a development build. Install MacStats as an app to use it.")
        }
        switch service.status {
        case .enabled: return L10n.string("MacStats will open when you log in.")
        case .notRegistered: return L10n.string("MacStats won't open automatically when you log in.")
        case .requiresApproval: return L10n.string("Allow MacStats in System Settings › General › Login Items to finish turning this on.")
        case .notFound: return L10n.string("macOS can't find MacStats' login item. Move MacStats to the Applications folder and try again.")
        @unknown default: return L10n.string("Couldn't check whether MacStats opens at login.")
        }
    }

    func register() throws {
        guard isSupported else { throw Failure.unsupported }
        do {
            try service.register()
        } catch {
            throw Failure.system(error.localizedDescription)
        }
    }

    func unregister() throws {
        guard isSupported else { throw Failure.unsupported }
        guard service.status != .notRegistered else { return }
        do {
            try service.unregister()
        } catch {
            throw Failure.system(error.localizedDescription)
        }
    }
}
