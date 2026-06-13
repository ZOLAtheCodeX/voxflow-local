import XCTest
@testable import VoxFlowApp

@MainActor
final class SnippetStoreTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    }

    private let reservedWords: Set<String> = [
        "memo", "mece", "items", "steel", "pyramid", "disclaimer",
        "cancel", "undo", "insert", "copy"
    ]

    // MARK: - add()

    func test_add_persists_and_reloads() {
        let url = tmpURL()
        let store = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "signoff", text: "Best regards, Pat", scope: .global))

        let reloaded = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.snippets.count, 1)
        XCTAssertEqual(reloaded.snippets.first?.keyword, "signoff")
        XCTAssertEqual(reloaded.snippets.first?.text, "Best regards, Pat")
        XCTAssertEqual(reloaded.snippets.first?.scope, .global)
    }

    func test_add_rejects_empty_keyword() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertFalse(store.add(keyword: "", text: "whatever", scope: .global))
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func test_add_rejects_whitespace_only_keyword() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertFalse(store.add(keyword: "   ", text: "whatever", scope: .global))
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func test_add_rejects_multiword_keyword() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertFalse(store.add(keyword: "two words", text: "whatever", scope: .global))
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func test_add_normalizes_keyword() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "  SignOff ", text: "Best regards", scope: .global))
        XCTAssertEqual(store.snippets.first?.keyword, "signoff")
    }

    // MARK: - remove()

    func test_remove_deletes_by_id() {
        let url = tmpURL()
        let store = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "signoff", text: "Best regards", scope: .global))
        let id = store.snippets[0].id
        store.remove(id)
        XCTAssertTrue(store.snippets.isEmpty)

        let reloaded = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(reloaded.snippets.isEmpty)
    }

    // MARK: - update()

    func test_update_changes_fields_preserves_id_and_createdAt() {
        let url = tmpURL()
        let store = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "signoff", text: "Best regards", scope: .global))
        let id = store.snippets[0].id
        let createdAt = store.snippets[0].createdAt

        XCTAssertTrue(store.update(id: id, keyword: "newword", text: "new text", scope: .longFormOnly))
        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets[0].id, id)
        XCTAssertEqual(store.snippets[0].createdAt, createdAt)
        XCTAssertEqual(store.snippets[0].keyword, "newword")
        XCTAssertEqual(store.snippets[0].text, "new text")
        XCTAssertEqual(store.snippets[0].scope, .longFormOnly)

        let reloaded = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.snippets.count, 1)
        XCTAssertEqual(reloaded.snippets[0].id, id)
        XCTAssertEqual(reloaded.snippets[0].createdAt, createdAt)
        XCTAssertEqual(reloaded.snippets[0].keyword, "newword")
        XCTAssertEqual(reloaded.snippets[0].text, "new text")
        XCTAssertEqual(reloaded.snippets[0].scope, .longFormOnly)
    }

    func test_update_unknown_id_returns_false() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "signoff", text: "Best regards", scope: .global))
        let snapshot = store.snippets
        XCTAssertFalse(store.update(id: UUID(), keyword: "newword", text: "new text", scope: .longFormOnly))
        XCTAssertEqual(store.snippets, snapshot)
    }

    func test_update_rejects_invalid_keyword() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "signoff", text: "Best regards", scope: .global))
        let id = store.snippets[0].id
        let snapshot = store.snippets
        XCTAssertFalse(store.update(id: id, keyword: "two words", text: "new text", scope: .longFormOnly))
        XCTAssertEqual(store.snippets, snapshot)
    }

    // MARK: - Seeding

    func test_seed_on_first_run_populates() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: true)
        XCTAssertEqual(store.snippets.count, SnippetStore.seedSnippets.count)
        XCTAssertEqual(store.snippets.map(\.keyword), SnippetStore.seedSnippets.map(\.keyword))
    }

    func test_seed_keywords_avoid_reserved_words() {
        for seed in SnippetStore.seedSnippets {
            XCTAssertFalse(reservedWords.contains(seed.keyword),
                           "Seed keyword '\(seed.keyword)' collides with a reserved word")
            XCTAssertFalse(seed.keyword.contains(" "),
                           "Seed keyword '\(seed.keyword)' must be a single word")
            XCTAssertEqual(SnippetStore.normalizedKeyword(seed.keyword), seed.keyword,
                           "Seed keyword '\(seed.keyword)' must already be normalized")
        }
    }

    func test_no_seed_when_flag_false() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func test_no_seed_when_file_exists() {
        let url = tmpURL()
        let first = SnippetStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(first.add(keyword: "signoff", text: "Best regards", scope: .global))

        let second = SnippetStore(fileURL: url, seedOnFirstRun: true)
        XCTAssertEqual(second.snippets.count, 1)
        XCTAssertEqual(second.snippets.first?.keyword, "signoff")
    }

    // MARK: - normalizedKeyword()

    func test_normalizedKeyword() {
        XCTAssertEqual(SnippetStore.normalizedKeyword("  Foo "), "foo")
        XCTAssertNil(SnippetStore.normalizedKeyword(""))
        XCTAssertNil(SnippetStore.normalizedKeyword("a b"))
        XCTAssertEqual(SnippetStore.normalizedKeyword("BAR"), "bar")
    }

    func test_normalizedKeyword_strips_boundary_punctuation() {
        XCTAssertEqual(SnippetStore.normalizedKeyword("sign."), "sign")
        XCTAssertEqual(SnippetStore.normalizedKeyword("note:"), "note")
    }

    func test_add_strips_boundary_punctuation() {
        let store = SnippetStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(keyword: "sign.", text: "Best regards", scope: .global))
        XCTAssertEqual(store.snippets.first?.keyword, "sign")
    }
}
