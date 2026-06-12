import Foundation

/// Narrow tokenizer seam so vocabulary biasing is testable without a loaded
/// WhisperKit model. WhisperKitSTTService adapts the real WhisperTokenizer.
protocol VocabularyTokenizing {
    var specialTokenThreshold: Int { get }
    func encodeText(_ text: String) -> [Int]
}

/// R5.1 — the personal dictionary biases RECOGNITION, not just
/// post-correction. Whisper conditions its decoder on prompt tokens as
/// "previous text"; a short glossary of the user's terms ("GDPR",
/// "WHEREFORE", client names) makes the model prefer those spellings at
/// transcription time. Kept deliberately small: prompt tokens cost decode
/// time on every request, and long prompts amplify Whisper's tendency to
/// hallucinate continuation text on silence (the energy gate and
/// TranscriptGate guard that flank).
enum VocabularyBiasing {
    static let maxTerms = 24
    static let maxPromptTokens = 100

    /// Unique right-side dictionary terms, order-preserving.
    static func terms(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let term = entry.right.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
        }
        return result
    }

    static func hint(terms: [String]) -> String {
        "Glossary: " + terms.prefix(maxTerms).joined(separator: ", ") + "."
    }

    static func promptTokens(terms: [String], tokenizer: VocabularyTokenizing) -> [Int]? {
        guard !terms.isEmpty else { return nil }
        let threshold = tokenizer.specialTokenThreshold
        var tokens = tokenizer.encodeText(hint(terms: terms)).filter { $0 < threshold }
        if tokens.count > maxPromptTokens {
            tokens = Array(tokens.prefix(maxPromptTokens))
        }
        return tokens.isEmpty ? nil : tokens
    }
}
