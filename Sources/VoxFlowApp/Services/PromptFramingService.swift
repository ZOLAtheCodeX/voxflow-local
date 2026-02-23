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

    static func frame(_ text: String, intent: PromptIntent) -> String {
        switch intent {
        case .email:
            return """
            Task: Draft an email based on the following instructions.

            Instructions: \(text)

            Constraints:
            - Professional tone unless otherwise specified
            - Concise — aim for 3-5 sentences
            - Include subject line suggestion

            Output format: Complete email with Subject and Body.
            """
        case .code:
            return """
            Task: \(text)

            Constraints:
            - Write clean, production-ready code
            - Include brief comments for non-obvious logic
            - Handle edge cases

            Output format: Code with explanation of approach.
            """
        case .explain:
            return """
            Task: Explain the following clearly and concisely.

            Topic: \(text)

            Constraints:
            - Assume intermediate knowledge level
            - Use concrete examples where helpful
            - Keep it under 200 words unless complexity requires more

            Output format: Clear explanation with examples.
            """
        case .creative:
            return """
            Task: \(text)

            Constraints:
            - Engaging and original
            - Match the tone implied in the instructions
            - Provide 2-3 variations if the output is short-form

            Output format: Creative content as described.
            """
        case .data:
            return """
            Task: \(text)

            Constraints:
            - Be precise and factual
            - Use structured format (bullets, tables) where appropriate
            - Call out assumptions

            Output format: Structured analysis.
            """
        case .general:
            return """
            Task: \(text)

            Please provide a thorough, well-structured response.
            """
        }
    }
}
