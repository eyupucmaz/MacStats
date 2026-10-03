import XCTest
@testable import MacStats

final class HistoryRingBufferTests: XCTestCase {

    func testFillsInOrderBeforeWrapping() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        XCTAssertEqual(Array(ring), [1, 2])
        XCTAssertEqual(ring.capacity, 3)
    }

    func testWrapAroundOverwritesTheOldest() {
        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1 ... 7 { ring.append(value) }
        XCTAssertEqual(Array(ring), [5, 6, 7])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.first, 5)
        XCTAssertEqual(ring.last, 7)
    }

    func testShrinkKeepsTheNewest() {
        var ring = RingBuffer<Int>(capacity: 5)
        for value in 1 ... 8 { ring.append(value) } // wrapped: [4, 5, 6, 7, 8]
        ring.resize(to: 2)
        XCTAssertEqual(Array(ring), [7, 8])
        ring.append(9)
        XCTAssertEqual(Array(ring), [8, 9])
    }

    func testGrowKeepsEverythingAndAcceptsMore() {
        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1 ... 5 { ring.append(value) } // [3, 4, 5]
        ring.resize(to: 5)
        XCTAssertEqual(Array(ring), [3, 4, 5])
        ring.append(6)
        ring.append(7)
        ring.append(8)
        XCTAssertEqual(Array(ring), [4, 5, 6, 7, 8])
    }

    func testRemoveAllKeepsCapacity() {
        var ring = RingBuffer<Int>(capacity: 2)
        for value in 1 ... 3 { ring.append(value) }
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        ring.append(4)
        XCTAssertEqual(Array(ring), [4])
        XCTAssertEqual(ring.capacity, 2)
    }

    func testCapacityIsAtLeastOne() {
        var ring = RingBuffer<Int>(capacity: 0)
        ring.append(1)
        ring.append(2)
        XCTAssertEqual(Array(ring), [2])
    }
}
