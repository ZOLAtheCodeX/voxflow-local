import Foundation

enum HallucinationFilter {
    private static let alwaysFiltered: Set<String> = Set([
        "thank you for watching.",
        "thank you for watching!",
        "thanks for watching.",
        "thanks for watching!",
        "thank you so much for watching.",
        "thank you so much for watching!",
        "subscribe to my channel.",
        "subscribe to the channel.",
        "subscribe for more.",
        "subscribe for more!",
        "please subscribe.",
        "like and subscribe.",
        "please like and subscribe.",
        "\u{266A}",
        "\u{266A}\u{266A}",
        "\u{266A}\u{266A}\u{266A}",
        "\u{266B}",
        "\u{266C}",
        "...",
        "\u{2026}",
        // Common Whisper silence hallucinations — filter at any duration.
        "hello.",
        "hello",
        "hi.",
        "hi",
        "hey.",
        "hey",
    ])

    private static let shortOnlyFiltered: Set<String> = Set([
        "thank you.",
        "thanks.",
        "bye.",
        "goodbye.",
        "you",
    ])

    /// Characters that Whisper may append to hallucinated greetings.
    private static let trailingPunctuation = CharacterSet(charactersIn: ".!?,;:…\"'")

    /// Pre-computed normalized (punctuation-stripped) versions for O(1) lookup.
    private static let alwaysFilteredNormalized: Set<String> = Set(
        alwaysFiltered.map { $0.trimmingCharacters(in: trailingPunctuation) }.filter { !$0.isEmpty }
    )
    private static let shortOnlyFilteredNormalized: Set<String> = Set(
        shortOnlyFiltered.map { $0.trimmingCharacters(in: trailingPunctuation) }.filter { !$0.isEmpty }
    )

    static func isLikelyHallucination(_ text: String, shortAudio: Bool) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return true }
        let lowered = stripped.lowercased()

        if alwaysFiltered.contains(lowered) {
            return true
        }

        // Normalize trailing punctuation so "hello!", "hello?", "hello," etc. match
        let normalized = lowered.trimmingCharacters(in: trailingPunctuation)
        if !normalized.isEmpty, normalized != lowered, alwaysFilteredNormalized.contains(normalized) {
            return true
        }

        if shortAudio {
            if shortOnlyFiltered.contains(lowered) || shortOnlyFilteredNormalized.contains(normalized) {
                return true
            }
            let words = lowered.split(whereSeparator: { $0.isWhitespace })
            if words.count >= 3, Set(words).count == 1 {
                return true
            }
        }

        return false
    }
}
