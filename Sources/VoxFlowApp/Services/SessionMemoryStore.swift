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

    func recent(limit: Int = 10) -> [TranscriptCandidate] {
        Array(items.suffix(limit).reversed())
    }

    func latest() -> TranscriptCandidate? {
        items.last
    }

    var count: Int { items.count }

    func clear() {
        items.removeAll()
    }
}
