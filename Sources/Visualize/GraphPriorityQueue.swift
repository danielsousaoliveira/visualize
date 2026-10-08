import Foundation

struct GraphPriorityQueue {
    private var heap: [String] = []
    private var indices: [String: Int] = [:]
    private var scores: [String: Int] = [:]

    init(scores: [String: Int]) {
        for id in scores.keys.sorted() {
            self.scores[id] = scores[id]
            indices[id] = heap.count
            heap.append(id)
            rise(heap.count - 1)
        }
    }

    mutating func pop() -> String? {
        guard let first = heap.first else { return nil }
        swap(0, heap.count - 1)
        heap.removeLast()
        indices[first] = nil
        scores[first] = nil
        if !heap.isEmpty { sink(0) }
        return first
    }

    mutating func adjust(_ id: String, by delta: Int) {
        guard let index = indices[id] else { return }
        scores[id, default: 0] += delta
        if delta < 0 { rise(index) }
        else { sink(index) }
    }

    private func precedes(_ a: String, _ b: String) -> Bool {
        scores[a] == scores[b] ? a < b : scores[a]! < scores[b]!
    }

    private mutating func swap(_ a: Int, _ b: Int) {
        heap.swapAt(a, b)
        indices[heap[a]] = a
        indices[heap[b]] = b
    }

    private mutating func rise(_ start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard precedes(heap[index], heap[parent]) else { break }
            swap(index, parent)
            index = parent
        }
    }

    private mutating func sink(_ start: Int) {
        var index = start
        while index * 2 + 1 < heap.count {
            var child = index * 2 + 1
            if child + 1 < heap.count && precedes(heap[child + 1], heap[child]) { child += 1 }
            guard precedes(heap[child], heap[index]) else { break }
            swap(index, child)
            index = child
        }
    }
}
