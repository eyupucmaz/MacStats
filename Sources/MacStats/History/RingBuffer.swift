import Foundation

/// A fixed-capacity FIFO: once full, each append overwrites the oldest element.
/// Index 0 is always the oldest element, `count - 1` the newest. Storage is reserved
/// up front, so appends never reallocate and the footprint is `capacity × stride`.
struct RingBuffer<Element>: RandomAccessCollection {
    private var storage: ContiguousArray<Element> = []
    /// Physical index of the oldest element. Stays 0 until the buffer first fills.
    private var head = 0
    private(set) var capacity: Int

    init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }

    subscript(position: Int) -> Element {
        storage[(head + position) % storage.count]
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Changes the capacity, keeping the newest `min(count, newCapacity)` elements.
    mutating func resize(to newCapacity: Int) {
        let newCapacity = Swift.max(1, newCapacity)
        guard newCapacity != capacity else { return }
        var resized = ContiguousArray<Element>()
        resized.reserveCapacity(newCapacity)
        resized.append(contentsOf: suffix(newCapacity))
        storage = resized
        head = 0
        capacity = newCapacity
    }
}
