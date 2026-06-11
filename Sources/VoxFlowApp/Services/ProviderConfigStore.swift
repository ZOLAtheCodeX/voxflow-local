import Foundation
import os

/// Kinds the backend's provider registry understands (provider_registry.py).
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama
    case openaiCompat = "openai_compat"
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .openaiCompat: return "OpenAI-compatible server (LM Studio, llama.cpp, vLLM)"
        case .openai: return "OpenAI API (cloud)"
        case .anthropic: return "Anthropic Claude API (cloud)"
        }
    }

    var isCloud: Bool { self == .openai || self == .anthropic }
}

/// One entry in providers.json — mirrors the backend's ProviderSpec.
/// API keys never live here: `apiKeyEnv` names the env var the app populates
/// from the Keychain at backend launch.
struct ProviderSpecModel: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: ProviderKind
    var baseURL: String?
    var model: String?
    var apiKeyEnv: String?
    var timeout: Double = 30.0

    enum CodingKeys: String, CodingKey {
        case id, kind, model, timeout
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
    }

    init(id: String, kind: ProviderKind, baseURL: String? = nil, model: String? = nil, apiKeyEnv: String? = nil, timeout: Double = 30.0) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKeyEnv = apiKeyEnv
        self.timeout = timeout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 30.0
    }
}

/// Owns providers.json (R3.6). The file is SHARED with the Python backend —
/// same path the backend's `load_provider_config()` reads at launch; the app
/// is the only writer. Mirrors the SnippetStore/ChainStore persistence
/// pattern. After any mutation the caller should restart the backend so the
/// registry re-reads the file (SettingsCoordinator handles that).
@MainActor
final class ProviderConfigStore: ObservableObject {
    @Published private(set) var providers: [ProviderSpecModel] = []
    @Published private(set) var chains: [String: [String]] = [:]

    static let tasks = ["polish", "smart_action"]

    private let fileURL: URL
    private let log = Logger(subsystem: "local.voxflow.app", category: "ProviderConfigStore")

    /// ~/Library/Application Support/VoxFlow/providers.json — MUST match the
    /// backend's `default_config_path()` in provider_registry.py.
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VoxFlow", isDirectory: true)
            .appendingPathComponent("providers.json")
    }

    nonisolated static func keychainAccount(for providerID: String) -> String {
        "voxflow.provider.\(providerID)"
    }

    nonisolated static func keyEnvName(for providerID: String) -> String {
        let sanitized = providerID.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "VOXFLOW_PROVIDER_KEY_\(String(sanitized))"
    }

    init(fileURL: URL = ProviderConfigStore.defaultFileURL) {
        self.fileURL = fileURL
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            log.error("createDirectory failed: \(error.localizedDescription)")
        }
        if let loaded = Self.load(from: fileURL) {
            providers = loaded.providers
            chains = loaded.chains
        } else {
            providers = [ProviderSpecModel(id: "ollama", kind: .ollama)]
            chains = Dictionary(uniqueKeysWithValues: Self.tasks.map { ($0, ["ollama"]) })
            save()
        }
    }

    /// Adds a provider. Rejects empty/whitespace ids and duplicates (no
    /// mutation, no save). Cloud kinds get a Keychain-backed key env name
    /// assigned automatically.
    @discardableResult
    func add(_ spec: ProviderSpecModel) -> Bool {
        let trimmedID = spec.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !providers.contains(where: { $0.id == trimmedID }) else { return false }
        var normalized = spec
        normalized.id = trimmedID
        if normalized.kind.isCloud, normalized.apiKeyEnv == nil {
            normalized.apiKeyEnv = Self.keyEnvName(for: trimmedID)
        }
        providers.append(normalized)
        save()
        return true
    }

    func remove(id: String) {
        guard id != "ollama" || providers.count > 1 else { return }
        providers.removeAll { $0.id == id }
        KeychainService.delete(account: Self.keychainAccount(for: id))
        for task in chains.keys {
            chains[task] = (chains[task] ?? []).filter { pid in providers.contains(where: { $0.id == pid }) }
            if chains[task]?.isEmpty == true {
                chains[task] = providers.first.map { [$0.id] } ?? []
            }
        }
        save()
    }

    /// Sets a task's fallback chain. Unknown provider ids are pruned; an
    /// empty result falls back to the first configured provider.
    func setChain(task: String, providerIDs: [String]) {
        let known = Set(providers.map(\.id))
        var pruned = providerIDs.filter { known.contains($0) }
        if pruned.isEmpty, let first = providers.first?.id { pruned = [first] }
        chains[task] = pruned
        save()
    }

    /// Env name -> Keychain value for every cloud provider with a stored key.
    /// SettingsCoordinator injects these into the backend launch environment.
    func keychainBackedKeys() -> [String: String] {
        var result: [String: String] = [:]
        for spec in providers {
            guard let envName = spec.apiKeyEnv else { continue }
            if let key = KeychainService.load(account: Self.keychainAccount(for: spec.id)), !key.isEmpty {
                result[envName] = key
            }
        }
        return result
    }

    // MARK: - Persistence (snake_case schema shared with the backend)

    private struct FileSchema: Codable {
        var version: Int = 1
        var providers: [ProviderSpecModel]
        var chains: [String: [String]]
    }

    private nonisolated static func load(from url: URL) -> (providers: [ProviderSpecModel], chains: [String: [String]])? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let schema = try? JSONDecoder().decode(FileSchema.self, from: data) else { return nil }
        guard !schema.providers.isEmpty else { return nil }
        return (schema.providers, schema.chains)
    }

    private func save() {
        let schema = FileSchema(providers: providers, chains: chains)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(schema)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("providers.json save failed: \(error.localizedDescription)")
        }
    }
}
