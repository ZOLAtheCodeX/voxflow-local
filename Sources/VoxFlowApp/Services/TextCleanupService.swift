import Foundation
import NaturalLanguage

enum TextCleanupService {

    static func replaceSpokenPunctuation(_ text: String) -> String {
        var result = text

        for (pattern, replacement) in TextCleanupRules.spokenPunctuation {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }

    static func removeRepeatedWords(_ text: String) -> String {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count > 1 else { return text }

        var result = [words[0]]
        for i in 1..<words.count {
            if words[i].lowercased() != words[i - 1].lowercased() {
                result.append(words[i])
            }
        }
        return result.joined(separator: " ")
    }

    static func splitAndRecase(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var nlSentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            nlSentences.append(String(text[range]).trimmingCharacters(in: .whitespaces))
            return true
        }

        // NLTokenizer may under-split on lowercase text; split further on
        // sentence-ending punctuation followed by whitespace.
        var sentences: [String] = []
        for chunk in nlSentences {
            // Insert a sentinel after sentence-ending punctuation + space
            let marked = chunk.replacingOccurrences(
                of: #"([.!?])\s+"#,
                with: "$1\u{001E}",
                options: .regularExpression
            )
            let subParts = marked.components(separatedBy: "\u{001E}")
            sentences.append(contentsOf: subParts)
        }

        let recased = sentences.map { sentence -> String in
            var s = sentence.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return s }
            let first = s.prefix(1).uppercased()
            s = first + s.dropFirst()
            return s
        }

        return recased.joined(separator: " ")
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func removeFillers(_ text: String) -> String {
        var result = text

        // Pass 0: Remove phrase fillers (multi-word)
        for (pattern, replacement) in TextCleanupRules.phraseFillers {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = normalizeWhitespace(result)

        // Pass 1: Remove always-fillers
        let words = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let afterAlways = words.filter { !TextCleanupRules.alwaysFillers.contains($0.lowercased()) }
        result = afterAlways.joined(separator: " ")

        // Pass 2: POS-aware removal of ambiguous fillers
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = result

        var removeRanges: [Range<String.Index>] = []
        tagger.enumerateTags(in: result.startIndex..<result.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            let word = String(result[range]).lowercased()
            if TextCleanupRules.ambiguousFillers.contains(word) {
                if tag != .verb && tag != .adjective && tag != .noun {
                    removeRanges.append(range)
                }
            }
            return true
        }

        // Remove in reverse order to preserve indices
        var kept = result
        for range in removeRanges.reversed() {
            kept.removeSubrange(range)
        }
        return normalizeWhitespace(kept)
    }

    // MARK: - Full pipeline

    /// Full cleanup pipeline. Steps applied depend on mode:
    /// - Raw: normalize + spoken punctuation (steps 1-2)
    /// - Light: + dedup + sentence split + filler removal + recase (steps 1-6)
    /// - Polish: + tone transform (steps 1-7)
    static func cleanup(_ text: String, mode: CleanupMode, tone: ToneStyle) -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }

        // Step 1: Normalize whitespace
        var result = normalizeWhitespace(text)

        // Step 2: Spoken punctuation
        result = replaceSpokenPunctuation(result)

        guard mode != .raw else { return normalizeWhitespace(result) }

        // Step 3: Repeated word removal
        result = removeRepeatedWords(result)

        // Step 4 + 6: Sentence split + recase
        result = splitAndRecase(result)

        // Step 5: Filler removal
        result = removeFillers(result)

        // Re-normalize after removals
        result = normalizeWhitespace(result)

        // Ensure trailing punctuation
        if !result.isEmpty && !".!?".contains(result.last!) {
            result += "."
        }

        // Re-capitalize first char after filler removal may have lowered it
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        guard mode != .light else { return result }

        // Step 7: Tone transform (polish only)
        result = applyTone(result, tone: tone)

        return result
    }

    // MARK: - Tone transforms

    static func applyTone(_ text: String, tone: ToneStyle) -> String {
        switch tone {
        case .neutral:
            return text
        case .concise:
            return applyConciseTone(text)
        case .formal:
            return applyFormalTone(text)
        case .friendly:
            return applyFriendlyTone(text)
        }
    }

    // MARK: - Concise

    private static func applyConciseTone(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in TextCleanupRules.hedgingPhrases + TextCleanupRules.softeners {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return normalizeWhitespace(result)
    }

    // MARK: - Formal

    private static func applyFormalTone(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in TextCleanupRules.contractions + TextCleanupRules.casualInterjections {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = normalizeWhitespace(result)
        if !result.isEmpty && !".!?".contains(result.last!) {
            result += "."
        }
        return result
    }

    // MARK: - Friendly

    private static func applyFriendlyTone(_ text: String) -> String {
        let sentences = text.components(separatedBy: ". ")
        let softened = sentences.map { sentence -> String in
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return trimmed }
            let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? ""
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = trimmed
            let (tag, _) = tagger.tag(at: trimmed.startIndex, unit: .word, scheme: .lexicalClass)
            if tag == .verb, firstWord != "I" {
                let lower = firstWord.lowercased()
                return "Let's " + lower + trimmed.dropFirst(firstWord.count)
            }
            return trimmed
        }
        return softened.joined(separator: ". ")
    }
}
