import Foundation
import os

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []

    private let fileURL: URL
    private let clock: SessionClock
    private let log = Logger(subsystem: "local.voxflow.app", category: "DictionaryStore")

    static let seedTerms: [(String, String)] = [
        ("iso forty two thousand one", "ISO 42001"),
        ("a i g p", "AIGP"), ("c i p t", "CIPT"),
        ("gdpr", "GDPR"), ("hipaa", "HIPAA"),
        ("wherefor", "WHEREFORE"), ("r c w", "RCW")
    ]

    init(fileURL: URL, clock: SessionClock = SystemClock(), seedOnFirstRun: Bool = true) {
        self.fileURL = fileURL
        self.clock = clock
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let loaded = Self.load(from: fileURL) {
            entries = loaded
        } else if seedOnFirstRun {
            entries = Self.seedTerms.map {
                DictionaryEntry(wrong: $0.0, right: $0.1, context: "seed", learnedAt: clock.currentTime())
            }
            save()
        }
    }

    func add(wrong: String, right: String, context: String?) {
        entries.append(DictionaryEntry(wrong: wrong, right: right, context: context, learnedAt: clock.currentTime()))
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    static func applyCorrections(_ text: String, using entries: [DictionaryEntry]) -> String {
        var result = text
        for entry in entries where !entry.wrong.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: entry.wrong) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.right))
        }
        return result
    }

    func apply(to text: String) -> String { Self.applyCorrections(text, using: entries) }

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
            if !wrong.isEmpty, !right.isEmpty, (wrong.lowercased() != right.lowercased() || wrong != right) {
                pairs.append(LearnedPair(wrong: wrong, right: right))
            }
        }
        return pairs
    }

    func learnFromEdit(before: String, after: String) {
        for p in Self.learn(before: before, after: after) {
            let exists = entries.contains { $0.wrong == p.wrong && $0.right == p.right }
            if !exists { add(wrong: p.wrong, right: p.right, context: "learned") }
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch { log.error("save failed: \(error.localizedDescription)") }
    }

    private static func load(from url: URL) -> [DictionaryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([DictionaryEntry].self, from: data)
    }
}
