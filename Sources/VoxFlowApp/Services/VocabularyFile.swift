import Foundation

struct VocabularyItem: Codable, Equatable, Sendable {
    var spoken: String?
    var written: String
    var prioritized: Bool? = nil

    var key: String {
        let source = (spoken ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return source.isEmpty ? "term:\(written.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" : "spoken:\(source)"
    }

    func validated() throws -> Self {
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSpoken = spoken ?? ""
        let spoken = originalSpoken.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !written.isEmpty, written.count <= 256, spoken.count <= 256,
              !originalSpoken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !written.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !written.contains(where: \.isNewline) else {
            throw VocabularyFileError.invalidEntry
        }
        return Self(spoken: spoken.isEmpty ? nil : spoken, written: written, prioritized: prioritized == true)
    }
}

enum VocabularyFileError: LocalizedError {
    case tooLarge, invalidEntry, invalidFile, unsupportedVersion, tooManyEntries
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Vocabulary files must be at most 1 MB."
        case .invalidEntry: "Each entry needs a preferred spelling, with at most 256 characters per field and no control characters."
        case .invalidFile: "Choose a UTF-8 term list or a VoxFlow vocabulary JSON file."
        case .unsupportedVersion: "This vocabulary format version is not supported."
        case .tooManyEntries: "A vocabulary can contain at most 5,000 entries."
        }
    }
}

enum VocabularyFile {
    struct Document: Codable {
        var schemaVersion: Int
        var entries: [VocabularyItem]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", entries }
    }

    static func decode(_ data: Data, isJSON: Bool) throws -> [VocabularyItem] {
        guard data.count <= 1_048_576 else { throw VocabularyFileError.tooLarge }
        let items: [VocabularyItem]
        if isJSON {
            let doc: Document
            do { doc = try JSONDecoder().decode(Document.self, from: data) }
            catch { throw VocabularyFileError.invalidFile }
            guard doc.schemaVersion == 1 else { throw VocabularyFileError.unsupportedVersion }
            items = doc.entries
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw VocabularyFileError.invalidFile }
            items = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { VocabularyItem(written: $0) }
        }
        guard items.count <= 5000 else { throw VocabularyFileError.tooManyEntries }
        return try items.map { try $0.validated() }
    }

    static func encode(_ items: [VocabularyItem]) throws -> Data {
        guard items.count <= 5000 else { throw VocabularyFileError.tooManyEntries }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(schemaVersion: 1, entries: items.map { try $0.validated() }))
        guard data.count <= 1_048_576 else { throw VocabularyFileError.tooLarge }
        return data
    }
}

struct VocabularyImportSummary: Equatable {
    var additions = 0
    var duplicates = 0
    var conflicts = 0
}

/// One compiled expression scans the original text once. Replacements are
/// applied from the end, so inserted output never becomes another rule's input.
struct CompiledVocabulary {
    private let expression: NSRegularExpression?
    private let replacements: [String: String]

    init(entries: [DictionaryEntry]) throws {
        var replacements: [String: String] = [:]
        var sources: [String] = []
        for entry in entries {
            let source = Self.key(entry.wrong)
            guard !source.isEmpty, replacements[source] == nil else { continue }
            replacements[source] = entry.right
            sources.append(source)
        }
        self.replacements = replacements
        guard !sources.isEmpty else { expression = nil; return }
        let alternatives = sources.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+") }
        expression = try NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])",
            options: [.caseInsensitive])
    }

    private static func key(_ source: String) -> String {
        source.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func apply(_ text: String) -> String {
        guard let expression else { return text }
        let original = text as NSString
        let result = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            guard let replacement = replacements[Self.key(original.substring(with: match.range))] else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}
