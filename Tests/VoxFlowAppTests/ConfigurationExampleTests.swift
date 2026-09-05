import XCTest
@testable import VoxFlowApp

/// Published setup files are part of the import contract, not private fixtures.
@MainActor
final class ConfigurationExampleTests: XCTestCase {
    private var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples")
    }

    func testPublishedVocabularyCanBeImportedAndRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dictionary.json")
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        let terms = try VocabularyFile.decode(Data(contentsOf: examples.appendingPathComponent("vocabulary.txt")), isJSON: false)
        let corrections = try VocabularyFile.decode(Data(contentsOf: examples.appendingPathComponent("vocabulary.json")), isJSON: true)
        XCTAssertTrue(store.importItems(terms))
        XCTAssertTrue(store.importItems(corrections, replaceConflicts: true))
        XCTAssertEqual(store.apply(to: "ack me"), "Acme")
        XCTAssertEqual(try store.previewImport(corrections).additions, 0)
        XCTAssertEqual(try store.previewImport(corrections).conflicts, 0)
        let restored = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(restored.entries, store.entries)
        XCTAssertEqual(try VocabularyFile.decode(restored.exportData(), isJSON: true).count, store.entries.count)
    }

    func testPublishedCLIProfilesKeepTheirDistinctInvocationSyntaxAndStartOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkillProfileStore(fileURL: directory.appendingPathComponent("skills.json"))
        let data = try Data(contentsOf: examples.appendingPathComponent("skill-profiles.json"))
        XCTAssertTrue(store.importProfiles(try SkillProfileFile.decode(data).profiles))
        XCTAssertNil(store.activeMatcher)
        XCTAssertEqual(try store.previewImport(SkillProfileFile.decode(data).profiles).duplicates, 2)
        for profile in store.profiles {
            XCTAssertTrue(store.activate(profile.id))
            let expected = profile.name.hasPrefix("Codex") ? "$research" : "/research"
            XCTAssertEqual(store.activeMatcher?.resolve("hey, use the research skill", targetBundleID: "com.apple.Terminal")?.command, expected)
            XCTAssertNil(store.activeMatcher?.resolve("research", targetBundleID: "com.apple.TextEdit"))
        }
        XCTAssertNil(try SkillProfileFile.decode(store.exportData()).activeProfileID)
    }
}
