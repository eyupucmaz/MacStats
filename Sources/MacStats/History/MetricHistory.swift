import Combine
import Foundation

/// In-memory history behind the detail pages: one fixed-capacity ring buffer of
/// `(Date, Double)` per series, sized to hold the last hour at that series' sampling
/// interval. Nothing is written to disk; quitting clears it.
///
/// Threading: main thread only, and deliberately unlocked. `StatsEngine` appends from
/// its main-thread delivery block, detail-only samplers record from the main thread,
/// and views query while rendering.
///
/// Gaps: a sample that arrives more than `gapFactor` × the series interval after the
/// previous one (sampling paused, a stalled tick) is preceded by a stored gap marker,
/// which queries return as `MetricPoint(value: nil)` so charts break the line there.
///
/// Memory: every series reserves `capacity × 16` bytes up front. Intervals are clamped
/// to at least `minimumInterval` and the store holds at most `maximumSeriesCount`
/// series, so the total stays under `memoryBudgetBytes` at any refresh interval.
final class MetricHistory: ObservableObject {
    /// How much history each series keeps.
    static let window: TimeInterval = 3_600
    /// A pause longer than this many intervals is stored as a break.
    static let gapFactor = 2.5
    /// Matches the engine's fastest refresh interval; bounds the largest buffer.
    static let minimumInterval: TimeInterval = 0.5
    /// 32 series × 7 562 entries × 16 bytes ≈ 3.7 MiB reserved at the 0.5 s minimum
    /// interval (≈ 4.2 MiB of heap once the allocator rounds each buffer up to whole pages).
    static let maximumSeriesCount = 32
    static let memoryBudgetBytes = 5 * 1_024 * 1_024
    /// Room for gap markers and timer jitter, so a full buffer still spans the window.
    private static let capacitySlack = 1.05

    /// One stored sample. A NaN value is a gap marker.
    struct Entry: Equatable {
        let date: Date
        let value: Double

        var isGap: Bool { value.isNaN }
        var point: MetricPoint { MetricPoint(date: date, value: isGap ? nil : value) }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.date == rhs.date && (lhs.value == rhs.value || (lhs.isGap && rhs.isGap))
        }
    }

    private struct Series {
        let unit: MetricUnit
        /// Set for detail-only samplers with their own cadence; nil follows the store.
        var fixedInterval: TimeInterval?
        var entries: RingBuffer<Entry>
    }

    /// Bumped once per batch of appends. Views observe this instead of the buffers,
    /// so a tick costs one change notification however many series it touched.
    @Published private(set) var revision = 0

    /// The interval series without a fixed one are sampled at (the engine's refresh).
    private(set) var sampleInterval: TimeInterval
    private let clock: () -> Date
    private var store: [String: Series] = [:]

    init(sampleInterval: TimeInterval = 1.0, clock: @escaping () -> Date = Date.init) {
        self.sampleInterval = Self.normalizedInterval(sampleInterval)
        self.clock = clock
    }

    static func normalizedInterval(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 1.0 }
        return max(seconds, minimumInterval)
    }

    /// Entries needed to cover `window` at `interval`.
    static func capacity(for interval: TimeInterval) -> Int {
        Int((window / normalizedInterval(interval) * capacitySlack).rounded(.up)) + 2
    }

    // MARK: - Configuration

    /// Re-sizes every series that follows the store interval, keeping its newest points.
    func setSampleInterval(_ seconds: TimeInterval) {
        let interval = Self.normalizedInterval(seconds)
        guard interval != sampleInterval else { return }
        sampleInterval = interval
        let capacity = Self.capacity(for: interval)
        for id in store.keys where store[id]?.fixedInterval == nil {
            store[id]?.entries.resize(to: capacity)
        }
        revision &+= 1
    }

    /// Creates a series ahead of its first sample. `interval` is for samplers with
    /// their own cadence (e.g. every 2 s); nil follows `sampleInterval`. Returns false
    /// when the store is already at `maximumSeriesCount`.
    @discardableResult
    func register(_ id: String, unit: MetricUnit, interval: TimeInterval? = nil) -> Bool {
        let fixed = interval.map(Self.normalizedInterval)
        if store[id] != nil {
            if store[id]?.fixedInterval != fixed {
                store[id]?.fixedInterval = fixed
                store[id]?.entries.resize(to: Self.capacity(for: fixed ?? sampleInterval))
            }
            return true
        }
        return create(id, unit: unit, fixedInterval: fixed)
    }

    private func create(_ id: String, unit: MetricUnit, fixedInterval: TimeInterval?) -> Bool {
        guard store.count < Self.maximumSeriesCount else { return false }
        store[id] = Series(unit: unit, fixedInterval: fixedInterval,
                           entries: RingBuffer(capacity: Self.capacity(for: fixedInterval ?? sampleInterval)))
        return true
    }

    /// Frees a series, e.g. one a detail sampler no longer feeds.
    func removeSeries(_ id: String) {
        guard store.removeValue(forKey: id) != nil else { return }
        revision &+= 1
    }

    func contains(_ id: String) -> Bool { store[id] != nil }

    /// Reserved storage across all series, in bytes (`capacity × stride`).
    var estimatedMemoryBytes: Int {
        store.values.reduce(0) { $0 + $1.entries.capacity * MemoryLayout<Entry>.stride }
    }

    // MARK: - Recording

    /// Appends one sample, creating the series on first use. `date` defaults to the
    /// clock. Non-finite values are ignored rather than stored. Returns false when the
    /// value was dropped.
    @discardableResult
    func record(_ value: Double, for id: String, unit: MetricUnit, at date: Date? = nil) -> Bool {
        guard append(value, for: id, unit: unit, at: date ?? clock()) else { return false }
        revision &+= 1
        return true
    }

    /// Appends the engine's per-tick samples in order with a single revision bump.
    func record(_ samples: [CoreMetricSample]) {
        guard !samples.isEmpty else { return }
        for sample in samples {
            sample.forEachValue { id, unit, value in
                append(value, for: id, unit: unit, at: sample.date)
            }
        }
        revision &+= 1
    }

    @discardableResult
    private func append(_ value: Double, for id: String, unit: MetricUnit, at date: Date) -> Bool {
        guard value.isFinite, store[id] != nil || create(id, unit: unit, fixedInterval: nil) else { return false }
        let interval = store[id]?.fixedInterval ?? sampleInterval
        // Read only the last entry: holding a copy of the buffer would make the append copy it.
        if let last = store[id]?.entries.last {
            if date < last.date {
                // The wall clock went backwards: older points no longer fit the timeline.
                store[id]?.entries.removeAll()
            } else if date.timeIntervalSince(last.date) > interval * Self.gapFactor {
                store[id]?.entries.append(Entry(date: last.date.addingTimeInterval(interval), value: .nan))
            }
        }
        store[id]?.entries.append(Entry(date: date, value: value))
        return true
    }

    // MARK: - Queries

    /// The last `range` of a series ending at `now` (default: the clock), downsampled
    /// to at most `maxPoints` with min/max bucketing. Nil for a series never recorded.
    func series(_ id: String, range: HistoryRange, maxPoints: Int = 300, now: Date? = nil) -> MetricSeries? {
        guard let stored = store[id] else { return nil }
        let end = now ?? clock()
        let start = end.addingTimeInterval(-range.duration)
        let slice = Self.slice(stored.entries, from: start, through: end)
        return MetricSeries(id: id, unit: stored.unit,
                            points: Self.downsample(slice, from: start, to: end, maxPoints: maxPoints))
    }

    /// Min / average / max over the non-gap points of `range` (raw, not downsampled).
    /// Nil when the range holds no values.
    func statistics(_ id: String, range: HistoryRange, now: Date? = nil) -> SeriesStatistics? {
        guard let stored = store[id] else { return nil }
        let end = now ?? clock()
        let slice = Self.slice(stored.entries, from: end.addingTimeInterval(-range.duration), through: end)
        var low = Double.infinity, high = -Double.infinity, sum = 0.0, count = 0
        for entry in slice where !entry.isGap {
            low = min(low, entry.value)
            high = max(high, entry.value)
            sum += entry.value
            count += 1
        }
        guard count > 0 else { return nil }
        return SeriesStatistics(min: low, average: sum / Double(count), max: high)
    }

    /// Entries dated within `start...end`. Dates are non-decreasing (a backwards clock
    /// clears the series), so both bounds are binary searches.
    private static func slice(_ entries: RingBuffer<Entry>, from start: Date,
                              through end: Date) -> Slice<RingBuffer<Entry>> {
        func firstIndex(where predicate: (Entry) -> Bool) -> Int {
            var low = entries.startIndex, high = entries.endIndex
            while low < high {
                let mid = (low + high) / 2
                if predicate(entries[mid]) { high = mid } else { low = mid + 1 }
            }
            return low
        }
        let lower = firstIndex { $0.date >= start }
        let upper = max(lower, firstIndex { $0.date > end })
        return entries[lower ..< upper]
    }

    /// Splits `start...end` into equal time buckets and keeps each bucket's minimum
    /// and maximum (in time order) so spikes survive, plus its first gap marker so
    /// breaks survive. Returns the entries unchanged when they already fit.
    static func downsample<C: Collection>(_ entries: C, from start: Date, to end: Date,
                                          maxPoints: Int) -> [MetricPoint] where C.Element == Entry {
        // Three is the most one bucket can emit (min, max, gap).
        let limit = max(maxPoints, 3)
        guard entries.count > limit else { return entries.map(\.point) }

        let hasGaps = entries.contains { $0.isGap }
        let bucketCount = limit / (hasGaps ? 3 : 2)
        let span = max(end.timeIntervalSince(start), .leastNormalMagnitude)

        var points: [MetricPoint] = []
        points.reserveCapacity(limit)
        var bucket = -1
        var low: Entry?, high: Entry?, gap: Entry?

        func flush() {
            var kept = [low, high, gap].compactMap { $0 }
            if let low, let high, low == high { kept.removeFirst() }
            kept.sort { $0.date < $1.date }
            points.append(contentsOf: kept.map(\.point))
            low = nil
            high = nil
            gap = nil
        }

        for entry in entries {
            let offset = entry.date.timeIntervalSince(start) / span * Double(bucketCount)
            let index = min(bucketCount - 1, max(0, Int(offset)))
            if index != bucket {
                flush()
                bucket = index
            }
            if entry.isGap {
                if gap == nil { gap = entry }
            } else {
                if entry.value < low?.value ?? .infinity { low = entry }
                if entry.value > high?.value ?? -.infinity { high = entry }
            }
        }
        flush()
        return points
    }
}
