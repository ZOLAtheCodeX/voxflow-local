import XCTest
@testable import VoxFlowApp

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    }
    func test_add_persists_and_reloads() {
        let url = tmpURL()
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        store.add(wrong: "wherefor", right: "WHEREFORE", context: nil)
        let reloaded = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.entries.map(\.right), ["WHEREFORE"])
    }
    func test_seed_on_first_run_only() {
        let url = tmpURL()
        let first = DictionaryStore(fileURL: url, seedOnFirstRun: true)
        XCTAssertFalse(first.entries.isEmpty)
        let count = first.entries.count
        let second = DictionaryStore(fileURL: url, seedOnFirstRun: true)
        XCTAssertEqual(second.entries.count, count)
    }
    func test_remove() {
        let url = tmpURL()
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        store.add(wrong: "a", right: "A", context: nil)
        let id = store.entries[0].id
        store.remove(id)
        XCTAssertTrue(store.entries.isEmpty)
    }
    func test_applyCorrections_whole_word_case_preserving() {
        let entries = [
            DictionaryEntry(wrong: "wherefor", right: "WHEREFORE", context: nil, learnedAt: .init()),
            DictionaryEntry(wrong: "gdpr", right: "GDPR", context: nil, learnedAt: .init())
        ]
        let out = DictionaryStore.applyCorrections("the wherefor clause under gdpr applies", using: entries)
        XCTAssertEqual(out, "the WHEREFORE clause under GDPR applies")
    }
    func test_applyCorrections_does_not_touch_substrings() {
        let entries = [DictionaryEntry(wrong: "art", right: "ART", context: nil, learnedAt: .init())]
        let out = DictionaryStore.applyCorrections("smart parties", using: entries)
        XCTAssertEqual(out, "smart parties")
    }
    func test_learn_single_word_substitution() {
        let pairs = DictionaryStore.learn(before: "the wherefor clause", after: "the WHEREFORE clause")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].wrong, "wherefor")
        XCTAssertEqual(pairs[0].right, "WHEREFORE")
    }
    func test_learn_skips_when_token_count_differs() {
        let pairs = DictionaryStore.learn(before: "the clause", after: "the WHEREFORE clause")
        XCTAssertTrue(pairs.isEmpty)
    }
    func test_learn_strips_trailing_punctuation() {
        let pairs = DictionaryStore.learn(before: "cited rcw.", after: "cited RCW.")
        XCTAssertEqual(pairs.map(\.right), ["RCW"])
    }
    func test_applyCorrections_multiword_seed() {
        let entries = [
            DictionaryEntry(wrong: "iso forty two thousand one", right: "ISO 42001",
                            context: nil, learnedAt: .init())
        ]
        let out = DictionaryStore.applyCorrections(
            "certified under iso forty two thousand one last year", using: entries)
        XCTAssertEqual(out, "certified under ISO 42001 last year")
    }
    func test_learnFromEdit_dedups_case_insensitively() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        store.add(wrong: "RCW", right: "RCW", context: nil)        // existing upper-case entry
        store.learnFromEdit(before: "see rcw now", after: "see RCW now")  // learns lower-case "rcw"
        XCTAssertEqual(store.entries.filter { $0.right == "RCW" }.count, 1)  // deduped, not 2
    }
}
