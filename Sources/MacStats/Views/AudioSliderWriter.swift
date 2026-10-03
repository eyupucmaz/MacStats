import Foundation

/// Rate limit for one slider: the first change writes immediately, changes
/// inside the interval are coalesced into one trailing write of the latest
/// value, so the final position is always written.
struct AudioWriteThrottle {
    enum Decision: Equatable {
        case write(Float)
        /// Hold the value and call `flush` after this many seconds.
        case schedule(after: TimeInterval)
        /// A flush is already scheduled; it will write this newer value.
        case coalesce
    }

    let interval: TimeInterval
    private(set) var lastWrite: TimeInterval?
    private(set) var pending: Float?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func submit(_ value: Float, at now: TimeInterval) -> Decision {
        if pending != nil {
            pending = value
            return .coalesce
        }
        if let lastWrite, now - lastWrite < interval {
            pending = value
            return .schedule(after: interval - (now - lastWrite))
        }
        lastWrite = now
        return .write(value)
    }

    /// Returns the held value, if any, and records it as written.
    mutating func flush(at now: TimeInterval) -> Float? {
        guard let value = pending else { return nil }
        pending = nil
        lastWrite = now
        return value
    }
}

enum AudioSliderKey: Hashable {
    case output
    case app(pid_t)
}

/// Throttles the Audio tab's slider writes so a drag does not issue a Core
/// Audio write (and read-back) per pixel. While a write is held back the
/// slider shows the dragged value from `drafts`, keeping the UI responsive.
@MainActor
final class AudioSliderWriter: ObservableObject {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Values the user dragged to that have not been written yet.
    @Published private(set) var drafts: [AudioSliderKey: Float] = [:]

    private let interval: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private var throttles: [AudioSliderKey: AudioWriteThrottle] = [:]
    private var writers: [AudioSliderKey: (Float) -> Void] = [:]

    /// About 20 writes a second: smooth enough to hear while dragging.
    nonisolated static let defaultInterval: TimeInterval = 0.05

    init(
        interval: TimeInterval = AudioSliderWriter.defaultInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = AudioSliderWriter.mainQueueScheduler
    ) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
    }

    /// The value a slider should show: the pending draft, else the service's.
    func value(for key: AudioSliderKey, current: Float?) -> Float? {
        drafts[key] ?? current
    }

    func send(_ value: Float, for key: AudioSliderKey, write: @escaping (Float) -> Void) {
        writers[key] = write
        var throttle = throttles[key] ?? AudioWriteThrottle(interval: interval)
        let decision = throttle.submit(value, at: now())
        throttles[key] = throttle

        switch decision {
        case let .write(value):
            drafts[key] = nil
            write(value)
        case let .schedule(delay):
            drafts[key] = value
            // Strong capture: the final value must land even if the tab closed.
            schedule(delay) { [self] in flush(key) }
        case .coalesce:
            drafts[key] = value
        }
    }

    /// Writes the held value for `key` now, e.g. when a drag ends.
    func flush(_ key: AudioSliderKey) {
        guard var throttle = throttles[key], let value = throttle.flush(at: now()) else { return }
        throttles[key] = throttle
        drafts[key] = nil
        writers[key]?(value)
    }

    func flushAll() {
        for key in Array(throttles.keys) { flush(key) }
    }

    nonisolated static func mainQueueScheduler(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            work()
        }
    }
}
