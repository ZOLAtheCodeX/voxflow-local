import Foundation
import os

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [VoiceSnippet] = []

    private let fileURL: URL
    private let clock: SessionClock
    private let log = Logger(subsystem: "local.voxflow.app", category: "SnippetStore")

    /// ~/Library/Application Support/VoxFlow/snippets.json — same resolution as the
    /// DictionaryStore wiring in AppCoordinator. `nonisolated` so a View's @StateObject
    /// default can reference it before the store's main-actor init runs; pure FileManager
    /// work, no actor state touched.
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VoxFlow", isDirectory: true)
            .appendingPathComponent("snippets.json")
    }

    /// Single-word, non-reserved seeds. Each keyword already equals its normalizedKeyword.
    static let seedSnippets: [(keyword: String, text: String, scope: SnippetScope)] = [
        ("signoff", "Best regards,\nZola Valashiya", .global),
        ("confidential", "CONFIDENTIAL — attorney work product. Do not distribute.", .global),
    ]

    init(fileURL: URL, clock: SessionClock = SystemClock(), seedOnFirstRun: Bool = true) {
        self.fileURL = fileURL
        self.clock = clock
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            log.error("createDirectory failed: \(error.localizedDescription)")
        }
        if let loaded = Self.load(from: fileURL) {
            snippets = loaded
        } else if seedOnFirstRun {
            let now = Self.wholeSeconds(clock.currentTime())
            snippets = Self.seedSnippets.map {
                VoiceSnippet(keyword: $0.keyword, text: $0.text, scope: $0.scope, createdAt: now)
            }
            save()
        }
    }

    /// Floors a date to whole seconds so `createdAt` is stable across the `.iso8601`
    /// JSON round-trip (which has 1-second resolution). Without this, an in-memory
    /// snippet's sub-second `createdAt` would not equal its reloaded value.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Normalizes keyword. Rejects (returns false, no mutation, no save) if the normalized
    /// keyword is nil (empty or contains internal whitespace). Else append + save.
    @discardableResult
    func add(keyword: String, text: String, scope: SnippetScope) -> Bool {
        guard let normalized = Self.normalizedKeyword(keyword) else { return false }
        snippets.append(VoiceSnippet(keyword: normalized, text: text, scope: scope, createdAt: Self.wholeSeconds(clock.currentTime())))
        save()
        return true
    }

    func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    /// Replace keyword/text/scope of snippet `id`, preserving id + createdAt. Returns false
    /// (no mutation, no save) if id not found OR keyword invalid.
    @discardableResult
    func update(id: UUID, keyword: String, text: String, scope: SnippetScope) -> Bool {
        guard let normalized = Self.normalizedKeyword(keyword) else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return false }
        let existing = snippets[index]
        snippets[index] = VoiceSnippet(id: existing.id, keyword: normalized, text: text, scope: scope, createdAt: existing.createdAt)
        save()
        return true
    }

    /// Delegates to ``VoiceCommandRouter/normalizedWord(_:)`` — the single source of truth for
    /// keyword/command normalization (lowercased, whitespace-trimmed, boundary punctuation
    /// stripped; nil if empty or multi-word). Sharing the normalizer guarantees a stored
    /// keyword can always match the voice-normalized spoken word — no "dead snippet" divergence.
    /// `nonisolated` so callers outside the main actor can use it synchronously — pure string
    /// work, no actor state.
    nonisolated static func normalizedKeyword(_ raw: String) -> String? {
        VoiceCommandRouter.normalizedWord(raw)
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snippets).write(to: fileURL, options: .atomic)
        } catch { log.error("save failed: \(error.localizedDescription)") }
    }

    private static func load(from url: URL) -> [VoiceSnippet]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([VoiceSnippet].self, from: data)
    }
}
