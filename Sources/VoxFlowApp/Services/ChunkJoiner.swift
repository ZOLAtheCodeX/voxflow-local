import Foundation

/// Joins two dictated chunks with the separator that reads naturally at the
/// seam. Pure and punctuation-aware: no separator after an opening mark or
/// before closing punctuation, exactly one space otherwise.
///
/// Known limitation: "3" + "14" joins as "3 14" (a number split across a
/// chunk boundary is indistinguishable from two numbers).
enum ChunkJoiner {
    private static let openers: Set<Character> = ["(", "[", "{", "“", "‘", "«", "¿", "¡"]
    private static let closers: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "»", "…", "%",
    ]

    static func join(_ previous: String, _ next: String) -> String {
        guard let first = next.first, let last = previous.last else {
            return previous + next
        }
        if last.isWhitespace || last.isNewline { return previous + next }
        if openers.contains(last) || closers.contains(first) { return previous + next }
        return previous + " " + next
    }
}
