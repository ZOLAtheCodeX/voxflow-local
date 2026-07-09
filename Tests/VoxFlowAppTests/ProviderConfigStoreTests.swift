import XCTest
@testable import VoxFlowApp

/// providers.json store (R3.6). The file is shared with the Python backend
/// (same path, same schema) — the backend reads it at launch; the app owns
/// writes. API keys never enter the file: each provider names an env var
/// (`api_key_env`) the app populates from the Keychain at backend launch.
@MainActor
final class ProviderConfigStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-tests-\(UUID().uuidString)")
            .appendingPathComponent("providers.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    /// Session 29 review: a merely-corrupt providers.json was silently
    /// overwritten with defaults — permanently destroying the user's
    /// provider/chain config and orphaning Keychain keys. The bad file is
    /// quarantined aside first so the config is recoverable.
    func testCorruptConfigIsQuarantinedNotDestroyed() throws {
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptBytes = Data("{not valid json".utf8)
        try corruptBytes.write(to: tempURL)

        let store = ProviderConfigStore(fileURL: tempURL)

        XCTAssertEqual(store.providers.map(\.id), ["ollama"], "defaults after corruption")
        XCTAssertTrue(store.recoveredFromCorruptConfig)
        let quarantine = tempURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try Data(contentsOf: quarantine), corruptBytes,
                       "original bytes must survive in the quarantine file")
    }

    func testMissingConfigSeedsDefaultsWithoutQuarantine() {
        let store = ProviderConfigStore(fileURL: tempURL)
        XCTAssertFalse(store.recoveredFromCorruptConfig)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempURL.appendingPathExtension("corrupt").path))
    }

    /// A failed save used to be log-only: Settings showed a provider the
    /// backend (which reads the file at launch) would never see, and the
    /// "added" config reverted at next launch.
    func testFailedSavePublishesSaveFailing() {
        // A path under a regular FILE can never be created — every save fails.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let impossible = blocker.appendingPathComponent("providers.json")

        let store = ProviderConfigStore(fileURL: impossible)
        XCTAssertTrue(store.saveFailing, "the seed save already failed")

        store.add(ProviderSpecModel(id: "lmstudio", kind: .openaiCompat))
        XCTAssertTrue(store.saveFailing)
    }

    func testSeededDefaultHasOllamaAndChains() {
        let store = ProviderConfigStore(fileURL: tempURL)
        XCTAssertEqual(store.providers.map(\.id), ["ollama"])
        XCTAssertEqual(store.chains["polish"], ["ollama"])
        XCTAssertEqual(store.chains["smart_action"], ["ollama"])
    }

    func testAddPersistsAndRoundTrips() {
        let store = ProviderConfigStore(fileURL: tempURL)
        XCTAssertTrue(store.add(ProviderSpecModel(
            id: "lmstudio", kind: .openaiCompat, baseURL: "http://localhost:1234", model: "qwen3:8b"
        )))
        let reloaded = ProviderConfigStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.providers.map(\.id), ["ollama", "lmstudio"])
        XCTAssertEqual(reloaded.providers.last?.baseURL, "http://localhost:1234")
    }

    func testDuplicateIdRejected() {
        let store = ProviderConfigStore(fileURL: tempURL)
        XCTAssertFalse(store.add(ProviderSpecModel(id: "ollama", kind: .ollama)))
        XCTAssertEqual(store.providers.count, 1)
    }

    func testEmptyOrWhitespaceIdRejected() {
        let store = ProviderConfigStore(fileURL: tempURL)
        XCTAssertFalse(store.add(ProviderSpecModel(id: "  ", kind: .ollama)))
    }

    func testCloudKindGetsKeychainBackedKeyEnv() {
        let store = ProviderConfigStore(fileURL: tempURL)
        _ = store.add(ProviderSpecModel(id: "claude", kind: .anthropic, model: "claude-haiku-4-5-20251001"))
        let spec = store.providers.first(where: { $0.id == "claude" })
        XCTAssertEqual(spec?.apiKeyEnv, "VOXFLOW_PROVIDER_KEY_CLAUDE")
        XCTAssertEqual(ProviderConfigStore.keychainAccount(for: "claude"), "voxflow.provider.claude")
    }

    func testRemoveDeletesAndPrunesChains() {
        let store = ProviderConfigStore(fileURL: tempURL)
        _ = store.add(ProviderSpecModel(id: "lmstudio", kind: .openaiCompat, baseURL: "http://localhost:1234", model: "m"))
        store.setChain(task: "polish", providerIDs: ["lmstudio", "ollama"])
        store.remove(id: "lmstudio")
        XCTAssertEqual(store.providers.map(\.id), ["ollama"])
        XCTAssertEqual(store.chains["polish"], ["ollama"])
    }

    func testSetChainRejectsUnknownProviders() {
        let store = ProviderConfigStore(fileURL: tempURL)
        store.setChain(task: "polish", providerIDs: ["ghost", "ollama"])
        XCTAssertEqual(store.chains["polish"], ["ollama"], "unknown ids must be pruned")
    }

    func testFileSchemaMatchesBackendContract() throws {
        // The Python loader expects snake_case keys: id, kind, base_url,
        // model, api_key_env, timeout + chains map. Pin the on-disk schema.
        let store = ProviderConfigStore(fileURL: tempURL)
        _ = store.add(ProviderSpecModel(id: "claude", kind: .anthropic, model: "m"))
        let data = try Data(contentsOf: tempURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        let providers = json?["providers"] as? [[String: Any]]
        XCTAssertEqual(providers?.count, 2)
        let claude = providers?.last
        XCTAssertEqual(claude?["kind"] as? String, "anthropic")
        XCTAssertEqual(claude?["api_key_env"] as? String, "VOXFLOW_PROVIDER_KEY_CLAUDE")
        XCTAssertNotNil(json?["chains"] as? [String: [String]])
    }
}
