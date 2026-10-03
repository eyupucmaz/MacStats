import Combine
import Foundation

/// First-run state for the welcome hint at the top of the popover.
///
/// The hint stays in the popover until the user dismisses it. The popover also
/// opens by itself once, on the very first launch, so the hint is seen before
/// the user has found the menu bar item; closing it without dismissing keeps
/// the hint for the next open but never opens the popover by itself again.
final class Onboarding: ObservableObject {
    static let shared = Onboarding()

    enum Key {
        static let popoverAutoOpened = "onboardingPopoverAutoOpened"
        static let hintDismissed = "onboardingHintDismissed"
    }

    private let defaults: UserDefaults

    @Published private(set) var isHintVisible: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isHintVisible = !defaults.bool(forKey: Key.hintDismissed)
    }

    /// True the first time it is asked on a fresh install, false ever after:
    /// the answer is persisted as soon as it is given.
    func consumeAutoOpen() -> Bool {
        guard isHintVisible, !defaults.bool(forKey: Key.popoverAutoOpened) else { return false }
        defaults.set(true, forKey: Key.popoverAutoOpened)
        return true
    }

    func dismissHint() {
        defaults.set(true, forKey: Key.hintDismissed)
        isHintVisible = false
    }
}
