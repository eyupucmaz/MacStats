import Foundation
import Combine

/// Fan state and (attempted) fan control, backed by the real SMC.
///
/// This type never simulates: `currentFanSpeed` is whatever `F0Ac` reports, and
/// a mode change is a genuine `F0md` + `F0Tg` write. Writing the SMC needs root
/// — and on Apple Silicon it is refused with `kIOReturnNotPrivileged` — so the
/// normal outcome is `isControlAvailable == false` plus a `lastError` the UI can
/// show. The selected mode stays selected, but no RPM is ever invented.
final class FanController: ObservableObject, @unchecked Sendable {

    static let shared = FanController()

    /// Measured RPM of fan 0. 0 when there is no fan or no reading.
    @Published private(set) var currentFanSpeed: Int = 0
    @Published private(set) var fanMode: FanMode = .auto
    @Published private(set) var customSpeed: Int = 1500
    @Published private(set) var minSpeed: Int = FanController.fallbackMinSpeed
    @Published private(set) var maxSpeed: Int = FanController.fallbackMaxSpeed

    /// Whether fan targets can actually be written on this machine.
    @Published private(set) var isControlAvailable: Bool = false
    /// Whether the SMC reports any fan at all (`FNum` > 0).
    @Published private(set) var isFanPresent: Bool = false
    /// Why the last control attempt failed, in words a user can read.
    @Published private(set) var lastError: String?

    enum FanMode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case silent = "Silent"
        case balanced = "Balanced"
        case max = "Max"
        case custom = "Custom"

        var id: String { rawValue }
    }

    // MARK: - Private state

    private enum DefaultsKey {
        static let mode = "fanMode"
        static let customSpeed = "fanCustomSpeed"
    }

    /// Only used when `F0Mn`/`F0Mx` cannot be read.
    private static let fallbackMinSpeed = 1000
    private static let fallbackMaxSpeed = 6000

    private let smc = SMCService.shared
    private let defaults: UserDefaults
    /// SMC I/O runs here so the main thread never waits on the kernel.
    private let queue = DispatchQueue(label: "MacStats.FanController", qos: .utility)

    // MARK: - Lifecycle

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        isFanPresent = smc.fanCount() > 0

        // Hardware limits; the constants are a last resort, not a default.
        let hardwareMin = smc.readFanMinRPM()
        let hardwareMax = smc.readFanMaxRPM()
        minSpeed = hardwareMin ?? Self.fallbackMinSpeed
        maxSpeed = Swift.max(minSpeed, hardwareMax ?? Self.fallbackMaxSpeed)

        // Restore the user's selection.
        if let stored = defaults.string(forKey: DefaultsKey.mode),
           let mode = FanMode(rawValue: stored) {
            fanMode = mode
        }
        let storedSpeed = defaults.object(forKey: DefaultsKey.customSpeed) as? Int
        customSpeed = Self.clamp(storedSpeed ?? (minSpeed + maxSpeed) / 2, min: minSpeed, max: maxSpeed)

        currentFanSpeed = smc.readFanRPM() ?? 0

        let support = controlSupport()
        isControlAvailable = support.available
        lastError = support.reason

        // The saved mode is restored for display only — nothing is written to
        // the SMC until the user picks a mode.
    }

    // MARK: - Reading

    /// Re-reads the actual RPM from the SMC and republishes it on the main thread.
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let present = self.smc.fanCount() > 0
            let rpm = self.smc.readFanRPM()
            self.publish {
                self.isFanPresent = present
                self.currentFanSpeed = rpm ?? 0
            }
        }
    }

    // MARK: - Control

    func setFanMode(_ mode: FanMode) {
        publish { self.fanMode = mode }
        defaults.set(mode.rawValue, forKey: DefaultsKey.mode)
        apply(mode)
    }

    func setCustomSpeed(_ speed: Int) {
        let clamped = Self.clamp(speed, min: minSpeed, max: maxSpeed)
        let modeIsCustom = fanMode == .custom
        publish { self.customSpeed = clamped }
        defaults.set(clamped, forKey: DefaultsKey.customSpeed)
        if modeIsCustom { apply(.custom) }
    }

    /// Hands the fan back to the SMC's own curve. Runs synchronously so it is
    /// safe to call from `applicationWillTerminate`.
    func restoreAutomaticControl() {
        let restored = smc.restoreAutoFanControl()
        let reason = restored ? nil : failureMessage(smc.lastWriteError)
        publish {
            self.isControlAvailable = restored
            self.lastError = reason
        }
    }

    // MARK: - Internals

    /// Target RPM for a mode; `nil` means "give control back to the SMC".
    /// Never exceeds `maxSpeed`.
    private func target(for mode: FanMode) -> Int? {
        switch mode {
        case .auto: return nil
        case .silent: return minSpeed
        case .balanced: return Self.clamp((minSpeed + maxSpeed) / 2, min: minSpeed, max: maxSpeed)
        case .max: return maxSpeed
        case .custom: return Self.clamp(customSpeed, min: minSpeed, max: maxSpeed)
        }
    }

    /// Attempts the real SMC write, then publishes the honest outcome.
    private func apply(_ mode: FanMode) {
        let requested = target(for: mode)
        queue.async { [weak self] in
            guard let self else { return }
            let succeeded: Bool
            if let requested {
                succeeded = self.smc.writeFanTarget(requested)
            } else {
                succeeded = self.smc.restoreAutoFanControl()
            }
            let reason = succeeded ? nil : self.failureMessage(self.smc.lastWriteError)
            let rpm = self.smc.readFanRPM()
            self.publish {
                self.isControlAvailable = succeeded
                self.lastError = reason
                self.currentFanSpeed = rpm ?? 0
            }
        }
    }

    /// Read-only capability check — no write is attempted at launch.
    private func controlSupport() -> (available: Bool, reason: String?) {
        guard smc.isAvailable else {
            return (false, "The SMC is not reachable on this Mac")
        }
        guard isFanPresent else {
            return (false, "No fan detected on this Mac")
        }
        guard smc.manualModeKey() != nil else {
            return (false, "This Mac exposes no writable fan-control key (F0Md/F0md)")
        }
        guard geteuid() == 0 else {
            return (false, "Fan control requires root and is not supported on this Mac")
        }
        // Keys exist and we are root: the write may still be refused, in which
        // case `apply` records the refusal.
        return (true, nil)
    }

    private func failureMessage(_ smcReason: String?) -> String {
        if geteuid() != 0 {
            return "Fan control requires root and is not supported on this Mac"
        }
        return smcReason ?? "The SMC refused the fan-control request"
    }

    /// `@Published` mutations must happen on the main thread.
    private func publish(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        Swift.max(lower, Swift.min(upper, value))
    }
}
