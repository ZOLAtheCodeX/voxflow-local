import Foundation
import NaturalLanguage

enum TextCleanupService {

    static func replaceSpokenPunctuation(_ text: String) -> String {
        var result = text

        let replacements: [(pattern: String, replacement: String)] = [
            (#"\s+new paragraph\b\s*"#, "\n\n"),
            (#"\s+new ?line\b\s*"#, "\n"),
            (#"\s+period\b"#, "."),
            (#"\s+full stop\b"#, "."),
            (#"\s+comma\b"#, ","),
            (#"\s+question mark\b"#, "?"),
            (#"\s+exclamation (?:point|mark)\b"#, "!"),
            (#"\s+colon\b"#, ":"),
            (#"\s+semicolon\b"#, ";"),
            (#"\bopen quote\s+"#, "\""),
            (#"\s+close quote\b"#, "\""),
            (#"\s+dash\b"#, " —"),
            (#"\s+hyphen\b"#, "-"),
        ]

        for (pattern, replacement) in replacements {
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

    private static let alwaysFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "err", "ah", "ahh", "hmm", "hm",
        "mm", "mmm", "mhm"
    ]

    private static let ambiguousFillers: Set<String> = [
        "like", "so", "right", "actually", "basically", "literally",
        "anyway", "anyways"
    ]

    private static let phraseFillers: [(pattern: String, replacement: String)] = [
        (#"\byou know\b"#, ""),
        (#"\bI mean\b"#, ""),
        (#"\bkind of\b"#, ""),
        (#"\bsort of\b"#, ""),
        (#"\bokay so\b"#, ""),
    ]

    static func removeFillers(_ text: String) -> String {
        var result = text

        // Pass 0: Remove phrase fillers (multi-word)
        for (pattern, replacement) in phraseFillers {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = normalizeWhitespace(result)

        // Pass 1: Remove always-fillers
        let words = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let afterAlways = words.filter { !alwaysFillers.contains($0.lowercased()) }
        result = afterAlways.joined(separator: " ")

        // Pass 2: POS-aware removal of ambiguous fillers
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = result

        var keepRanges: [Range<String.Index>] = []
        tagger.enumerateTags(in: result.startIndex..<result.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            let word = String(result[range]).lowercased()
            if ambiguousFillers.contains(word) {
                if tag == .verb || tag == .adjective || tag == .noun {
                    keepRanges.append(range)
                }
            } else {
                keepRanges.append(range)
            }
            return true
        }

        let kept = keepRanges.map { String(result[$0]) }.joined(separator: " ")
        return normalizeWhitespace(kept)
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

    private static let hedgingPhrases: [(String, String)] = [
        (#"\bI think maybe\b"#, ""),
        (#"\bit seems like\b"#, ""),
        (#"\bin my opinion\b"#, ""),
        (#"\bI feel like\b"#, ""),
        (#"\bI guess\b"#, ""),
        (#"\bto be honest\b"#, ""),
    ]

    private static let softeners: [(String, String)] = [
        (#"\bjust\b"#, ""),
        (#"\breally\b"#, ""),
        (#"\bvery\b"#, ""),
        (#"\bquite\b"#, ""),
        (#"\ba bit\b"#, ""),
    ]

    private static func applyConciseTone(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in hedgingPhrases + softeners {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return normalizeWhitespace(result)
    }

    // MARK: - Formal

    private static let contractions: [(String, String)] = [
        (#"\bdon\u{2019}t\b"#, "do not"),
        (#"\bdon't\b"#, "do not"),
        (#"\bcan\u{2019}t\b"#, "cannot"),
        (#"\bcan't\b"#, "cannot"),
        (#"\bwon\u{2019}t\b"#, "will not"),
        (#"\bwon't\b"#, "will not"),
        (#"\bshouldn\u{2019}t\b"#, "should not"),
        (#"\bshouldn't\b"#, "should not"),
        (#"\bwouldn\u{2019}t\b"#, "would not"),
        (#"\bwouldn't\b"#, "would not"),
        (#"\bcouldn\u{2019}t\b"#, "could not"),
        (#"\bcouldn't\b"#, "could not"),
        (#"\bisn\u{2019}t\b"#, "is not"),
        (#"\bisn't\b"#, "is not"),
        (#"\baren\u{2019}t\b"#, "are not"),
        (#"\baren't\b"#, "are not"),
        (#"\bwasn\u{2019}t\b"#, "was not"),
        (#"\bwasn't\b"#, "was not"),
        (#"\bweren\u{2019}t\b"#, "were not"),
        (#"\bweren't\b"#, "were not"),
        (#"\bhasn\u{2019}t\b"#, "has not"),
        (#"\bhasn't\b"#, "has not"),
        (#"\bhaven\u{2019}t\b"#, "have not"),
        (#"\bhaven't\b"#, "have not"),
        (#"\bhadn\u{2019}t\b"#, "had not"),
        (#"\bhadn't\b"#, "had not"),
        (#"\bdoesn\u{2019}t\b"#, "does not"),
        (#"\bdoesn't\b"#, "does not"),
        (#"\bdidn\u{2019}t\b"#, "did not"),
        (#"\bdidn't\b"#, "did not"),
        (#"\bI\u{2019}m\b"#, "I am"),
        (#"\bI'm\b"#, "I am"),
        (#"\bI\u{2019}ve\b"#, "I have"),
        (#"\bI've\b"#, "I have"),
        (#"\bI\u{2019}ll\b"#, "I will"),
        (#"\bI'll\b"#, "I will"),
        (#"\bI\u{2019}d\b"#, "I would"),
        (#"\bI'd\b"#, "I would"),
        (#"\bwe\u{2019}re\b"#, "we are"),
        (#"\bwe're\b"#, "we are"),
        (#"\bwe\u{2019}ve\b"#, "we have"),
        (#"\bwe've\b"#, "we have"),
        (#"\bwe\u{2019}ll\b"#, "we will"),
        (#"\bwe'll\b"#, "we will"),
        (#"\bthey\u{2019}re\b"#, "they are"),
        (#"\bthey're\b"#, "they are"),
        (#"\bthey\u{2019}ve\b"#, "they have"),
        (#"\bthey've\b"#, "they have"),
        (#"\bthey\u{2019}ll\b"#, "they will"),
        (#"\bthey'll\b"#, "they will"),
        (#"\byou\u{2019}re\b"#, "you are"),
        (#"\byou're\b"#, "you are"),
        (#"\byou\u{2019}ve\b"#, "you have"),
        (#"\byou've\b"#, "you have"),
        (#"\byou\u{2019}ll\b"#, "you will"),
        (#"\byou'll\b"#, "you will"),
        (#"\bit\u{2019}s\b"#, "it is"),
        (#"\bit's\b"#, "it is"),
        (#"\bthat\u{2019}s\b"#, "that is"),
        (#"\bthat's\b"#, "that is"),
        (#"\bwho\u{2019}s\b"#, "who is"),
        (#"\bwho's\b"#, "who is"),
        (#"\bwhat\u{2019}s\b"#, "what is"),
        (#"\bwhat's\b"#, "what is"),
        (#"\bthere\u{2019}s\b"#, "there is"),
        (#"\bthere's\b"#, "there is"),
        (#"\bhere\u{2019}s\b"#, "here is"),
        (#"\bhere's\b"#, "here is"),
        (#"\blet\u{2019}s\b"#, "let us"),
        (#"\blet's\b"#, "let us"),
    ]

    private static let casualInterjections: [(String, String)] = [
        (#"\bokay so\b"#, ""),
        (#"\balright\b"#, ""),
        (#"\bhey\b"#, ""),
        (#"\byeah\b"#, "yes"),
        (#"\bnope\b"#, "no"),
    ]

    private static func applyFormalTone(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in contractions + casualInterjections {
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
