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
                return "Launch at Login needs MacStats to run from an installed .app bundle."
            case .system(let message):
                return message
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
            return "Unavailable — MacStats is not running from an .app bundle."
        }
        switch SMAppService.mainApp.status {
        case .enabled: return "Registered with launchd."
        case .notRegistered: return "Not registered."
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items."
        case .notFound: return "Login item not found."
        @unknown default: return "Unknown status."
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
