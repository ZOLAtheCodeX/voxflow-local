import Foundation
import NaturalLanguage

enum PromptFramingService {

    private static let intentKeywords: [(intent: PromptIntent, phrases: [String])] = [
        (.email, ["email", "reply", "message to", "follow up", "follow-up"]),
        (.code, ["\\bfunction\\b", "\\bcode\\b", "debug", "refactor", "review", "implement", "\\bapi\\b", "endpoint", "algorithm", "\\bclass\\b", "\\bmethod\\b"]),
        (.explain, ["explain", "what is", "how does", "teach", "break down", "why does", "how do"]),
        (.creative, ["blog", "tweet", "post", "story", "tagline", "\\bcopy\\b", "headline", "slogan", "draft"]),
        (.data, ["summarize", "compare", "extract", "analyze", "list the", "differences between", "table of"]),
    ]

    private static func phraseMatches(_ phrase: String, in text: String) -> Bool {
        if phrase.contains("\\b") {
            return text.range(of: phrase, options: .regularExpression) != nil
        }
        return text.contains(phrase)
    }

    static func detectIntent(_ text: String) -> PromptIntent {
        let lowered = text.lowercased()
        guard !lowered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .general
        }

        var scores: [PromptIntent: Int] = [:]
        for (intent, phrases) in intentKeywords {
            let count = phrases.filter { phraseMatches($0, in: lowered) }.count
            if count > 0 {
                scores[intent] = count
            }
        }

        guard !scores.isEmpty else {
            return .general
        }

        let priority: [PromptIntent] = [.email, .code, .explain, .creative, .data]
        let maxScore = scores.values.max()!
        for intent in priority {
            if scores[intent] == maxScore {
                return intent
            }
        }

        return .general
    }
}
