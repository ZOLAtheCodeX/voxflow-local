import Foundation
import os

/// Cockpit Layer 1 — Phase E. Persists the user's workflow chains.
///
/// Mirrors ``SnippetStore``: JSON on disk (prettyPrinted/sortedKeys/.iso8601,
/// atomic write), `createdAt` floored to whole seconds for stable round-trips,
/// seed-on-first-run, and a `nonisolated static defaultFileURL`. Chains are
/// keyed by a normalized name (case-insensitive, internal spaces preserved) so
/// add/lookup share the exact same normalization — no "dead" entries.
@MainActor
final class ChainStore: ObservableObject {
    @Published private(set) var chains: [WorkflowChain] = []

    private let fileURL: URL
    private let clock: SessionClock
    private let log = Logger(subsystem: "local.voxflow.app", category: "ChainStore")

    /// ~/Library/Application Support/VoxFlow/chains.json — same resolution as the
    /// SnippetStore/DictionaryStore wiring. `nonisolated` so a default arg can
    /// reference it before the store's main-actor init runs; pure FileManager
    /// work, no actor state touched.
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VoxFlow", isDirectory: true)
            .appendingPathComponent("chains.json")
    }

    /// Seed chains. Deliberately contain NO `.capture` step — they must be
    /// useful applied to the text already captured in the cockpit, since the
    /// executor seeds from the current transcript (no live mid-chain recording).
    static let seedChains: [(name: String, steps: [ChainStep])] = [
        ("Memo", [.action(actionId: .memo), .insert(targetHint: nil)]),
        ("Action items", [.action(actionId: .items), .insert(targetHint: nil)]),
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
            chains = loaded
        } else if seedOnFirstRun {
            let now = Self.wholeSeconds(clock.currentTime())
            chains = Self.seedChains.map {
                WorkflowChain(name: $0.name, steps: $0.steps, createdAt: now)
            }
            save()
        }
    }

    /// Floors a date to whole seconds so `createdAt` is stable across the
    /// `.iso8601` JSON round-trip (1-second resolution). Without this, an
    /// in-memory chain's sub-second `createdAt` would not equal its reloaded
    /// value.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Append a chain. Rejects (returns false, no mutation, no save) when the
    /// name is empty/whitespace, the steps are empty, or another chain already
    /// has the same normalized name.
    @discardableResult
    func add(name: String, steps: [ChainStep]) -> Bool {
        guard let normalized = Self.normalizedName(name), !steps.isEmpty else { return false }
        guard !chains.contains(where: { Self.normalizedName($0.name) == normalized }) else { return false }
        chains.append(WorkflowChain(name: name, steps: steps, createdAt: Self.wholeSeconds(clock.currentTime())))
        save()
        return true
    }

    func remove(_ id: UUID) {
        chains.removeAll { $0.id == id }
        save()
    }

    /// Replace name/steps of chain `id`, preserving id + createdAt. Returns false
    /// (no mutation, no save) when id not found, name invalid, steps empty, or
    /// the new name collides with a *different* chain's normalized name.
    @discardableResult
    func update(id: UUID, name: String, steps: [ChainStep]) -> Bool {
        guard let normalized = Self.normalizedName(name), !steps.isEmpty else { return false }
        guard let index = chains.firstIndex(where: { $0.id == id }) else { return false }
        let collides = chains.contains { $0.id != id && Self.normalizedName($0.name) == normalized }
        guard !collides else { return false }
        let existing = chains[index]
        chains[index] = WorkflowChain(id: existing.id, name: name, steps: steps, createdAt: existing.createdAt)
        save()
        return true
    }

    /// Normalize a chain name: trimmed + lowercased, internal spaces preserved.
    /// Returns nil if empty after trimming. Deliberately NOT delegated to
    /// ``VoiceCommandRouter/normalizedWord(_:)`` — that is single-word and strips
    /// boundary punctuation, which would mangle multi-word chain names like
    /// "Memo Flow". `nonisolated` so callers outside the main actor (and the
    /// add/update dup-check) can use it synchronously — pure string work.
    nonisolated static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// Look up a chain by name. Normalizes the query through the same function
    /// used at storage time, so a stored chain is always findable (no dead
    /// entries from normalization divergence).
    func chain(named raw: String) -> WorkflowChain? {
        guard let normalized = Self.normalizedName(raw) else { return nil }
        return chains.first { Self.normalizedName($0.name) == normalized }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(chains).write(to: fileURL, options: .atomic)
        } catch { log.error("save failed: \(error.localizedDescription)") }
    }

    private static func load(from url: URL) -> [WorkflowChain]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([WorkflowChain].self, from: data)
    }
}
