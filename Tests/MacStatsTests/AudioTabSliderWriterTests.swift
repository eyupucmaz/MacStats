import Foundation
import XCTest
@testable import MacStats

final class AudioTabWriteThrottleTests: XCTestCase {
    func testFirstValueWritesImmediately() {
        var throttle = AudioWriteThrottle(interval: 0.05)
        XCTAssertEqual(throttle.submit(0.4, at: 10), .write(0.4))
        XCTAssertNil(throttle.pending)
    }

    func testValuesInsideTheIntervalCoalesceIntoOneTrailingWrite() {
        var throttle = AudioWriteThrottle(interval: 0.05)
        _ = throttle.submit(0.40, at: 10)

        guard case let .schedule(delay) = throttle.submit(0.41, at: 10.01) else {
            return XCTFail("expected a scheduled flush")
        }
        XCTAssertEqual(delay, 0.04, accuracy: 1e-9)
        XCTAssertEqual(throttle.submit(0.42, at: 10.02), .coalesce)
        XCTAssertEqual(throttle.submit(0.43, at: 10.03), .coalesce)

        XCTAssertEqual(throttle.flush(at: 10.05), 0.43)
        XCTAssertNil(throttle.flush(at: 10.06), "a flush with nothing held writes nothing")
    }

    func testValueAfterTheIntervalWritesImmediately() {
        var throttle = AudioWriteThrottle(interval: 0.05)
        _ = throttle.submit(0.4, at: 10)
        XCTAssertEqual(throttle.submit(0.6, at: 10.2), .write(0.6))
    }

    func testFlushRestartsTheInterval() {
        var throttle = AudioWriteThrottle(interval: 0.05)
        _ = throttle.submit(0.4, at: 10)
        _ = throttle.submit(0.5, at: 10.01)
        _ = throttle.flush(at: 10.05)
        guard case let .schedule(delay) = throttle.submit(0.6, at: 10.06) else {
            return XCTFail("expected a scheduled flush")
        }
        XCTAssertEqual(delay, 0.04, accuracy: 1e-9)
    }
}

@MainActor
final class AudioTabSliderWriterTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    private var written: [Float] = []

    private func makeWriter() -> AudioSliderWriter {
        AudioSliderWriter(
            interval: 0.05,
            now: { [unowned self] in clock },
            schedule: { [unowned self] delay, work in scheduled.append((delay, work)) }
        )
    }

    private func runScheduled() {
        let pending = scheduled
        scheduled = []
        for (_, work) in pending { work() }
    }

    func testDragWritesLeadingAndFinalValuesOnly() {
        let writer = makeWriter()
        for (index, value) in stride(from: Float(0.1), through: 0.5, by: 0.1).enumerated() {
            clock = 100 + Double(index) * 0.01
            writer.send(value, for: .output) { self.written.append($0) }
        }

        XCTAssertEqual(written, [0.1])
        XCTAssertEqual(scheduled.count, 1, "one trailing flush for the whole burst")
        XCTAssertEqual(writer.value(for: .output, current: 0.1) ?? 0, 0.5, accuracy: 1e-6,
                       "the slider keeps showing the dragged value while the write is held")

        clock = 100.05
        runScheduled()

        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.last ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertNil(writer.drafts[.output])
        XCTAssertEqual(writer.value(for: .output, current: 0.3), 0.3, "after the write the service is the source of truth")
    }

    func testFlushOnDragEndWritesTheFinalValueOnce() {
        let writer = makeWriter()
        writer.send(0.2, for: .output) { self.written.append($0) }
        clock += 0.01
        writer.send(0.7, for: .output) { self.written.append($0) }

        writer.flush(.output)
        runScheduled()

        XCTAssertEqual(written, [0.2, 0.7], "the late timer finds nothing left to write")
    }

    func testKeysAreThrottledIndependently() {
        let writer = makeWriter()
        var safari: [Float] = []
        var music: [Float] = []
        writer.send(0.3, for: .app(1)) { safari.append($0) }
        writer.send(0.9, for: .app(2)) { music.append($0) }
        clock += 0.01
        writer.send(0.4, for: .app(1)) { safari.append($0) }

        writer.flushAll()

        XCTAssertEqual(safari, [0.3, 0.4])
        XCTAssertEqual(music, [0.9])
    }

    func testTrailingWriteUsesTheLatestWriteClosure() {
        let writer = makeWriter()
        var first: [Float] = []
        var second: [Float] = []
        writer.send(0.3, for: .app(1)) { first.append($0) }
        clock += 0.01
        writer.send(0.4, for: .app(1)) { second.append($0) }
        runScheduled()

        XCTAssertEqual(first, [0.3])
        XCTAssertEqual(second, [0.4])
    }
}
