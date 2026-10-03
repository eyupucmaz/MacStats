import Foundation

/// Who a process is and which row it is accounted under. Resolved once per process
/// lifetime (PID + start time) and cached by `ProcessSampler`.
struct ProcessIdentity {
    /// Executable basename, or `proc_name` when the path is unavailable.
    let name: String
    /// The `.app` bundle this process is grouped under; nil for a standalone process.
    let groupBundlePath: String?
    /// The `.app` bundle whose main executable this process is; nil for helpers inside a bundle.
    let ownBundlePath: String?
    /// Set only for an app bundle's main executable that LaunchServices knows about.
    let app: ProcessAppInfo?

    init(name: String, groupBundlePath: String? = nil, ownBundlePath: String? = nil, app: ProcessAppInfo? = nil) {
        self.name = name
        self.groupBundlePath = groupBundlePath
        self.ownBundlePath = ownBundlePath
        self.app = app
    }

    /// The grouping rule: anything whose executable lives inside a `.app` is accounted under
    /// the outermost bundle, so "Google Chrome Helper (Renderer)" (nested deep inside
    /// Google Chrome.app) counts as Google Chrome. The exception is a nested bundle that is
    /// itself a regular Dock app (e.g. Simulator inside Xcode), which keeps its own row.
    /// `lookupApp` runs only for a bundle's main executable, keeping LaunchServices
    /// queries to the processes that can be apps.
    static func make(path: String?, fallbackName: String, lookupApp: () -> ProcessAppInfo?) -> ProcessIdentity {
        let name = path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        guard let path else { return ProcessIdentity(name: name) }

        let bundles = appBundles(in: path)
        guard let outermost = bundles.first else { return ProcessIdentity(name: name) }
        guard let own = bundle(ownedByMainExecutable: path, bundles: bundles) else {
            return ProcessIdentity(name: name, groupBundlePath: outermost)
        }
        let app = lookupApp()
        let group = (own != outermost && app?.isRegular == true) ? own : outermost
        return ProcessIdentity(name: name, groupBundlePath: group, ownBundlePath: own, app: app)
    }

    /// Every `.app` directory on the path, outermost first.
    static func appBundles(in path: String) -> [String] {
        var bundles: [String] = []
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true).dropLast() {
            prefix += "/" + component
            if component.lowercased().hasSuffix(".app") { bundles.append(prefix) }
        }
        return bundles
    }

    /// The innermost bundle when `path` is exactly `<bundle>/Contents/MacOS/<executable>`.
    static func bundle(ownedByMainExecutable path: String, bundles: [String]) -> String? {
        guard let innermost = bundles.last else { return nil }
        let remainder = path.dropFirst(innermost.count).split(separator: "/")
        guard remainder.count == 3, remainder[0] == "Contents", remainder[1] == "MacOS" else { return nil }
        return innermost
    }

    /// "Google Chrome" for ".../Google Chrome.app".
    static func displayName(ofBundle path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }
}
