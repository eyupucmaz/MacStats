import Foundation
import ServiceManagement

/// Wrapper over `SMAppService.mainApp`. Only functional when the executable runs
/// from a real `.app` bundle — a bare SPM binary has no launchd-registerable app record.
enum LaunchAtLogin {
    enum Failure: LocalizedError {
        /// Not running from a `.app` bundle (e.g. `swift run` / `./.build/debug/MacStats`).
        case unsupported
        case system(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "Launch at Login only works when MacStats is installed as an app, not in a development build."
            case .system(let message):
                return "Couldn't change Launch at Login: \(message)"
            }
        }
    }

    /// `SMAppService` silently no-ops (or throws) outside a bundle, so gate on it.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Human-readable state for the settings UI.
    static var statusDescription: String {
        guard isSupported else {
            return "Not available in a development build. Install MacStats as an app to use it."
        }
        switch SMAppService.mainApp.status {
        case .enabled: return "MacStats will open when you log in."
        case .notRegistered: return "MacStats won't open automatically when you log in."
        case .requiresApproval: return "Allow MacStats in System Settings › General › Login Items to finish turning this on."
        case .notFound: return "macOS can't find MacStats' login item. Move MacStats to the Applications folder and try again."
        @unknown default: return "Couldn't check whether MacStats opens at login."
        }
    }

    static func register() throws {
        guard isSupported else { throw Failure.unsupported }
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw Failure.system(error.localizedDescription)
        }
    }

    static func unregister() throws {
        guard isSupported else { throw Failure.unsupported }
        guard SMAppService.mainApp.status != .notRegistered else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw Failure.system(error.localizedDescription)
        }
    }
}
