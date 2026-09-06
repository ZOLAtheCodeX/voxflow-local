import XCTest
@testable import VoxFlowApp

@MainActor
final class VocabularyImportTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-\(UUID().uuidString).json")
    }

    func testTermListImportAndPortableRoundTrip() throws {
        let items = try VocabularyFile.decode(Data("\u{feff}Acme\r\n\nISO 42001\nAcme\n".utf8), isJSON: false)
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(try store.previewImport(items), VocabularyImportSummary(additions: 2, duplicates: 1))
        XCTAssertTrue(store.importItems(items))
        XCTAssertEqual(store.entries.map(\.right), ["Acme", "ISO 42001"])
        XCTAssertEqual(store.apply(to: "the Acme meeting"), "the Acme meeting")
        let exported = try store.exportData()
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(text.contains("learnedAt"))
        XCTAssertFalse(text.contains("context"))
        XCTAssertFalse(text.contains(url.path))
        XCTAssertEqual(try VocabularyFile.decode(exported, isJSON: true).map(\.written), ["Acme", "ISO 42001"])
        let reloaded = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    func testConflictPreviewDefaultsToKeepingExistingAndCanExplicitlyReplace() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        store.add(wrong: "ack me", right: "Acme", context: "manual")
        let originalID = try XCTUnwrap(store.entries.first?.id)
        let incoming = [VocabularyItem(spoken: "ACK ME", written: "ACME", prioritized: true)]
        XCTAssertEqual(try store.previewImport(incoming).conflicts, 1)
        XCTAssertTrue(store.importItems(incoming))
        XCTAssertEqual(store.apply(to: "ack me"), "Acme")
        XCTAssertTrue(store.importItems(incoming, replaceConflicts: true))
        XCTAssertEqual(store.apply(to: "ack me"), "ACME")
        XCTAssertEqual(store.entries.first?.id, originalID)
        XCTAssertEqual(store.entries.first?.prioritized, true)
    }

    func testLegacyFileLoadsAndPrioritySurvivesEditAndRestart() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        [{"id":"74C6A3EA-0B92-41C8-968C-EF72B26B65F3","wrong":"old","right":"Old","learnedAt":"2026-01-01T00:00:00Z"}]
        """
        try Data(legacy.utf8).write(to: url)
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.update(id: id, spoken: "new term", written: "NewTerm", prioritized: true))
        XCTAssertEqual(store.apply(to: "a NEW TERM here"), "a NewTerm here")
        let reloaded = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.entries.first?.id, id)
        XCTAssertEqual(reloaded.entries.first?.prioritized, true)
        XCTAssertEqual(reloaded.apply(to: "new term"), "NewTerm")
    }

    func testFailedSaveKeepsMemoryDiskAndCompiledMatcherUnchanged() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        initial.add(wrong: "old", right: "Original", context: nil)
        let data = try Data(contentsOf: url)
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false, writer: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertFalse(store.importItems([VocabularyItem(spoken: "new", written: "New")]))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.entries, initial.entries)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(store.apply(to: "old and new"), "Original and new")
    }

    func testUnreadableExistingFileIsNeverReplacedBySeedsOrAnEdit() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("[{unfinished".utf8)
        try corrupt.write(to: url)
        let store = DictionaryStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.add(wrong: "x", right: "Y", context: nil))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testMalformedUnsupportedAndOversizedImportsFailWithoutPartialMutation() throws {
        XCTAssertThrowsError(try VocabularyFile.decode(Data("{".utf8), isJSON: true))
        XCTAssertThrowsError(try VocabularyFile.decode(Data("{\"schema_version\":2,\"entries\":[]}".utf8), isJSON: true))
        XCTAssertThrowsError(try VocabularyFile.decode(Data(repeating: 97, count: 1_048_577), isJSON: false))
        XCTAssertThrowsError(try VocabularyFile.decode(Data([0xFF, 0xFE]), isJSON: false))
        XCTAssertThrowsError(try VocabularyFile.decode(Data(String(repeating: "term\n", count: 5001).utf8), isJSON: false))
        let store = DictionaryStore(fileURL: file(), seedOnFirstRun: false)
        XCTAssertFalse(store.importItems([VocabularyItem(written: "Valid"), VocabularyItem(written: " ")]))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testLongestMatchLiteralOutputUnicodeBoundariesAndNoCascade() throws {
        let pairs = [("new", "NEW"), ("new york", "NYC"), ("alpha", "beta"), ("beta", "gamma"),
                     ("c++", "$Code\\1"), ("école", "ÉCOLE"), ("art", "ART")]
        let entries = pairs.map { DictionaryEntry(wrong: $0.0, right: $0.1, context: nil, learnedAt: .init()) }
        let matcher = try CompiledVocabulary(entries: entries)
        XCTAssertEqual(matcher.apply("new   york, new, alpha beta; C++; école; smart parties; dart_1"),
                       "NYC, NEW, beta gamma; $Code\\1; ÉCOLE; smart parties; dart_1")
        XCTAssertEqual(matcher.apply("écarté écolettes école"), "écarté écolettes ÉCOLE")
    }

    func testPrioritizedTermsPrecedeSeedsWithoutExpandingRecognitionBudget() {
        var entries = (0..<30).map { DictionaryEntry(wrong: "", right: "Term\($0)", context: "seed", learnedAt: .init()) }
        entries[29].prioritized = true
        let terms = VocabularyBiasing.terms(from: entries)
        XCTAssertEqual(terms.first, "Term29")
        XCTAssertTrue(VocabularyBiasing.hint(terms: terms).contains("Term29"))
        XCTAssertFalse(VocabularyBiasing.hint(terms: terms).contains("Term28"))
        XCTAssertEqual(VocabularyBiasing.maxTerms, 24)
    }
}
