import Foundation

final class SessionMemoryStore {
    private let capacity: Int
    private var items: [TranscriptCandidate] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func push(candidate: TranscriptCandidate) {
        items.append(candidate)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    func latest() -> TranscriptCandidate? {
        items.last
    }

    func clear() {
        items.removeAll()
    }
}
