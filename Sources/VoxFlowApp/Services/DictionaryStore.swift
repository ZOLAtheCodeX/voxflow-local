import Foundation
import os

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let clock: SessionClock
    private let writer: (Data, URL) throws -> Void
    private var loadFailed = false
    private var compiled: CompiledVocabulary?

    static let seedTerms: [(String, String)] = [
        ("iso forty two thousand one", "ISO 42001"),
        ("a i g p", "AIGP"), ("c i p t", "CIPT"),
        ("gdpr", "GDPR"), ("hipaa", "HIPAA"),
        ("wherefor", "WHEREFORE"), ("r c w", "RCW")
    ]

    init(fileURL: URL, clock: SessionClock = SystemClock(), seedOnFirstRun: Bool = true,
         writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.fileURL = fileURL
        self.clock = clock
        self.writer = writer
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let loaded = try decoder.decode([DictionaryEntry].self, from: Data(contentsOf: fileURL))
                compiled = try CompiledVocabulary(entries: loaded)
                entries = loaded
            } else if seedOnFirstRun {
                _ = commit(Self.seedTerms.map {
                    DictionaryEntry(wrong: $0.0, right: $0.1, context: "seed", learnedAt: now)
                })
            }
        } catch {
            loadFailed = true
            lastError = "Could not read dictionary.json. The original file was preserved. Restore it from a backup or move it aside, then reopen VoxFlow. \(error.localizedDescription)"
        }
    }

    private var now: Date { Date(timeIntervalSince1970: clock.currentTime().timeIntervalSince1970.rounded(.down)) }

    private func commit(_ next: [DictionaryEntry]) -> Bool {
        guard !loadFailed else { return false }
        do {
            guard next.count <= 5000 else { throw VocabularyFileError.tooManyEntries }
            _ = try VocabularyFile.encode(next.map(Self.item))
            let matcher = try CompiledVocabulary(entries: next)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try writer(encoder.encode(next), fileURL)
            compiled = matcher
            entries = next
            lastError = nil
            return true
        } catch {
            lastError = "Vocabulary was not changed: \(error.localizedDescription)"
            return false
        }
    }

    static func item(for entry: DictionaryEntry) -> VocabularyItem {
        VocabularyItem(spoken: entry.wrong.isEmpty ? nil : entry.wrong,
                       written: entry.right, prioritized: entry.prioritized == true)
    }

    @discardableResult
    func add(wrong: String, right: String, context: String?, prioritized: Bool = false) -> Bool {
        do {
            let item = try VocabularyItem(spoken: wrong, written: right).validated()
            if let existing = entries.first(where: { Self.item(for: $0).key == item.key }) {
                guard existing.right != item.written else { lastError = nil; return true }
                lastError = "That spoken form already has a different spelling. Edit the existing entry."
                return false
            }
            return commit(entries + [DictionaryEntry(wrong: item.spoken ?? "", right: item.written,
                                                      context: context, learnedAt: now, prioritized: prioritized)])
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func update(id: UUID, spoken: String, written: String, prioritized: Bool) -> Bool {
        do {
            let item = try VocabularyItem(spoken: spoken, written: written, prioritized: prioritized).validated()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            guard !entries.contains(where: { $0.id != id && Self.item(for: $0).key == item.key }) else {
                lastError = "Another entry already uses that spoken form."
                return false
            }
            var next = entries
            let old = next[index]
            next[index] = DictionaryEntry(id: old.id, wrong: item.spoken ?? "", right: item.written,
                                           context: old.context, learnedAt: old.learnedAt, prioritized: prioritized)
            return commit(next)
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func setPrioritized(_ id: UUID, _ prioritized: Bool) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return update(id: id, spoken: entry.wrong, written: entry.right, prioritized: prioritized)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool { commit(entries.filter { $0.id != id }) }

    func previewImport(_ items: [VocabularyItem]) throws -> VocabularyImportSummary {
        try merged(items, replaceConflicts: false).summary
    }

    @discardableResult
    func importItems(_ items: [VocabularyItem], replaceConflicts: Bool = false) -> Bool {
        do { return commit(try merged(items, replaceConflicts: replaceConflicts).entries) }
        catch { lastError = error.localizedDescription; return false }
    }

    private func merged(_ items: [VocabularyItem], replaceConflicts: Bool) throws
        -> (entries: [DictionaryEntry], summary: VocabularyImportSummary) {
        var next = entries
        var summary = VocabularyImportSummary()
        var indices: [String: Int] = [:]
        for (index, entry) in next.enumerated() { indices[Self.item(for: entry).key] = indices[Self.item(for: entry).key] ?? index }
        for raw in items {
            let item = try raw.validated()
            if let index = indices[item.key] {
                let old = next[index]
                if Self.item(for: old) == item { summary.duplicates += 1; continue }
                summary.conflicts += 1
                if replaceConflicts {
                    next[index] = DictionaryEntry(id: old.id, wrong: item.spoken ?? "", right: item.written,
                                                  context: old.context, learnedAt: old.learnedAt, prioritized: item.prioritized)
                }
            } else {
                indices[item.key] = next.count
                next.append(DictionaryEntry(wrong: item.spoken ?? "", right: item.written,
                                             context: "imported", learnedAt: now, prioritized: item.prioritized))
                summary.additions += 1
            }
        }
        guard next.count <= 5000 else { throw VocabularyFileError.tooManyEntries }
        return (next, summary)
    }

    func exportData() throws -> Data { try VocabularyFile.encode(entries.map(Self.item)) }

    static func applyCorrections(_ text: String, using entries: [DictionaryEntry]) -> String {
        (try? CompiledVocabulary(entries: entries))?.apply(text) ?? text
    }

    func apply(to text: String) -> String { compiled?.apply(text) ?? text }

    struct LearnedPair: Equatable { let wrong: String; let right: String }

    static func learn(before: String, after: String) -> [LearnedPair] {
        let b = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let a = after.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard b.count == a.count, !b.isEmpty else { return [] }
        let punct = CharacterSet.punctuationCharacters
        var pairs: [LearnedPair] = []
        for (bw, aw) in zip(b, a) where bw != aw {
            let wrong = bw.trimmingCharacters(in: punct)
            let right = aw.trimmingCharacters(in: punct)
            if !wrong.isEmpty, !right.isEmpty, wrong != right {
                pairs.append(LearnedPair(wrong: wrong, right: right))
            }
        }
        return pairs
    }

    func learnFromEdit(before: String, after: String) {
        for p in Self.learn(before: before, after: after) {
            let exists = entries.contains { $0.wrong.lowercased() == p.wrong.lowercased() && $0.right == p.right }
            if !exists { add(wrong: p.wrong, right: p.right, context: "learned") }
        }
    }

}
