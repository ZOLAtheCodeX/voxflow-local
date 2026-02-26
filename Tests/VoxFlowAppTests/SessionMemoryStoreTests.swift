import XCTest
@testable import VoxFlowApp

final class SessionMemoryStoreTests: XCTestCase {

    func testInitialization() {
        // Test normal capacity
        let store1 = SessionMemoryStore(capacity: 5)
        XCTAssertEqual(store1.count, 0)

        // Test capacity clamped to at least 1
        let store2 = SessionMemoryStore(capacity: 0)
        let store3 = SessionMemoryStore(capacity: -5)

        let candidate = TranscriptCandidate(rawText: "A", lightText: "A", polishText: "A", selectedMode: .raw)

        store2.push(candidate: candidate)
        store2.push(candidate: candidate)
        XCTAssertEqual(store2.count, 1, "Capacity should be 1 even if 0 was passed")

        store3.push(candidate: candidate)
        store3.push(candidate: candidate)
        XCTAssertEqual(store3.count, 1, "Capacity should be 1 even if negative was passed")
    }

    func testPushIncrementsCount() {
        let store = SessionMemoryStore(capacity: 5)
        let candidate = TranscriptCandidate(rawText: "A", lightText: "A", polishText: "A", selectedMode: .raw)

        store.push(candidate: candidate)
        XCTAssertEqual(store.count, 1)

        store.push(candidate: candidate)
        XCTAssertEqual(store.count, 2)
    }

    func testPushRespectsCapacity() {
        let store = SessionMemoryStore(capacity: 2)
        let c1 = TranscriptCandidate(rawText: "1", lightText: "1", polishText: "1", selectedMode: .raw)
        let c2 = TranscriptCandidate(rawText: "2", lightText: "2", polishText: "2", selectedMode: .raw)
        let c3 = TranscriptCandidate(rawText: "3", lightText: "3", polishText: "3", selectedMode: .raw)

        store.push(candidate: c1)
        store.push(candidate: c2)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.latest()?.rawText, "2")

        store.push(candidate: c3)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.latest()?.rawText, "3")

        // Verify c1 was removed
        let recent = store.recent(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].rawText, "3")
        XCTAssertEqual(recent[1].rawText, "2")
    }

    func testLatest() {
        let store = SessionMemoryStore(capacity: 5)
        XCTAssertNil(store.latest())

        let c1 = TranscriptCandidate(rawText: "1", lightText: "1", polishText: "1", selectedMode: .raw)
        store.push(candidate: c1)
        XCTAssertEqual(store.latest()?.rawText, "1")

        let c2 = TranscriptCandidate(rawText: "2", lightText: "2", polishText: "2", selectedMode: .raw)
        store.push(candidate: c2)
        XCTAssertEqual(store.latest()?.rawText, "2")
    }

    func testRecentOrderingAndLimit() {
        let store = SessionMemoryStore(capacity: 10)
        let c1 = TranscriptCandidate(rawText: "1", lightText: "1", polishText: "1", selectedMode: .raw)
        let c2 = TranscriptCandidate(rawText: "2", lightText: "2", polishText: "2", selectedMode: .raw)
        let c3 = TranscriptCandidate(rawText: "3", lightText: "3", polishText: "3", selectedMode: .raw)

        store.push(candidate: c1)
        store.push(candidate: c2)
        store.push(candidate: c3)

        // Recent should be newest first
        let allRecent = store.recent(limit: 10)
        XCTAssertEqual(allRecent.count, 3)
        XCTAssertEqual(allRecent[0].rawText, "3")
        XCTAssertEqual(allRecent[1].rawText, "2")
        XCTAssertEqual(allRecent[2].rawText, "1")

        // Respect limit
        let limitedRecent = store.recent(limit: 2)
        XCTAssertEqual(limitedRecent.count, 2)
        XCTAssertEqual(limitedRecent[0].rawText, "3")
        XCTAssertEqual(limitedRecent[1].rawText, "2")

        // Default limit is 10
        let defaultRecent = store.recent()
        XCTAssertEqual(defaultRecent.count, 3)
    }

    func testClear() {
        let store = SessionMemoryStore(capacity: 5)
        let candidate = TranscriptCandidate(rawText: "A", lightText: "A", polishText: "A", selectedMode: .raw)

        store.push(candidate: candidate)
        store.push(candidate: candidate)
        XCTAssertEqual(store.count, 2)

        store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.latest())
        XCTAssertTrue(store.recent().isEmpty)
    }
}
