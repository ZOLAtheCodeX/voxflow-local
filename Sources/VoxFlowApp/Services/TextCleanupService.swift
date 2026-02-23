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
}
