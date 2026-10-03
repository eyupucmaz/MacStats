import Foundation

/// Who a process is and which row it is accounted under. Resolved once per process
/// lifetime (PID + start time) and cached by `ProcessSampler`.
struct ProcessIdentity {
    /// Executable basename, or `proc_name` when the path is unavailable. A basename that
    /// says nothing (a version number) gives way to argv[0] or a folder; see `readableName`.
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
    /// queries to the processes that can be apps. `firstArgument` (argv[0]) is asked for
    /// only when the executable's own name is unhelpful.
    static func make(path: String?, fallbackName: String, lookupApp: () -> ProcessAppInfo?,
                     firstArgument: () -> String? = { nil }) -> ProcessIdentity {
        let basename = path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let name = readableName(basename, path: path, firstArgument: firstArgument)
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

    /// `name`, unless it is a version number or empty, as with tools that install one
    /// executable per release (Claude Code runs as "~/.local/share/claude/versions/2.1.288").
    /// Then the basename of argv[0] ("claude"), or failing that the nearest meaningful
    /// folder on `path`, names the process.
    static func readableName(_ name: String, path: String?, firstArgument: () -> String?) -> String {
        guard isUnhelpfulName(name) else { return name }
        if let argument = firstArgument() {
            let base = (argument as NSString).lastPathComponent
            if !isUnhelpfulName(base) { return base }
        }
        // Up to three folders up, skipping hidden and generic ones ("versions", "bin").
        for folder in (path ?? "").split(separator: "/").dropLast().reversed().prefix(3) {
            let folder = String(folder)
            if !isUnhelpfulName(folder), !folder.hasPrefix("."), !genericFolders.contains(folder.lowercased()) {
                return folder
            }
        }
        return name
    }

    /// Empty, a bare number, or a version such as "2.1.288", "v20.11.1" or "1.4.0-beta.2".
    static func isUnhelpfulName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            || trimmed.range(of: #"^(\d+|[vV]?\d+(\.\d+)+([+-][0-9A-Za-z.]+)?)$"#, options: .regularExpression) != nil
    }

    /// Folders that say where a binary sits rather than what it is.
    private static let genericFolders: Set<String> = [
        "versions", "version", "bin", "sbin", "libexec", "lib", "macos", "current", "latest",
        "release", "releases", "build", "dist", "out", "contents", "resources",
    ]

    /// "Google Chrome" for ".../Google Chrome.app".
    static func displayName(ofBundle path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }
}
