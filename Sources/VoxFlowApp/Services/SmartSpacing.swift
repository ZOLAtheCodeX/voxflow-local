import Foundation

/// R5.0 — boundary-aware insertion spacing. Successive dictations used to
/// land back-to-back ("test.I've tested"); a space is prepended when the
/// character before the cursor needs one and the insertion starts a word.
enum SmartSpacing {
    private static let noSpaceAfter: Set<Character> = [
        " ", "\t", "\n", "\r", "(", "[", "{", "\"", "'", "“", "‘", "/", "-",
    ]

    static func adjusted(_ text: String, precedingCharacter: Character?) -> String {
        guard let preceding = precedingCharacter else { return text }
        guard !noSpaceAfter.contains(preceding) else { return text }
        guard let first = text.first, first.isLetter || first.isNumber else { return text }
        return " " + text
    }
}
