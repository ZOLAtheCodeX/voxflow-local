import Foundation

enum HallucinationFilter {
    private static let alwaysFilteredSingleWords: Set<String> = [
        "hello", "hi", "hey"
    ]
    
    private static let shortOnlySingleWords: Set<String> = [
        "bye", "goodbye", "you", "thanks", "yeah", "yes", "okay", "ok"
    ]
    
    // Extracted target second words for 2-word greetings
    private static let greetingTargets: Set<String> = [
        "everyone", "everybody", "guys", "there"
    ]

    static func isLikelyHallucination(_ text: String, shortAudio: Bool) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return true }
        
        // F4: Bracket/paren heuristics — only filter if the entire string is enclosed
        if (stripped.hasPrefix("[") && stripped.hasSuffix("]")) ||
           (stripped.hasPrefix("(") && stripped.hasSuffix(")")) ||
           (stripped.hasPrefix("*") && stripped.hasSuffix("*")) {
            let inner = stripped.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
            if inner.contains("typing") || inner.contains("clack") || inner.contains("keyboard") || inner.contains("silence") || inner.contains("noise") {
                return true
            }
        }
        
        // Extract pure word tokens (ignoring ALL punctuation and whitespace)
        let words = stripped.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            
        guard !words.isEmpty else { return true }
        
        // 1. If it's just 1 or 2 words, check if they are known standalone hallucinations
        if words.count <= 2 {
            if words.allSatisfy({ alwaysFilteredSingleWords.contains($0) }) {
                return true
            }
            if shortAudio && words.allSatisfy({ alwaysFilteredSingleWords.contains($0) || shortOnlySingleWords.contains($0) }) {
                return true
            }
            // "thank you" (short only)
            if shortAudio && words == ["thank", "you"] { return true }
            // "hello everyone", "hi guys", etc. (always filtered)
            if words.count == 2 && alwaysFilteredSingleWords.contains(words[0]) && greetingTargets.contains(words[1]) { return true }
        }
        
        // 2. Check for repeats (e.g. "hello. hello, hello!")
        // F5: Repeats should only be filtered on short audio, and require >= 3 words to avoid dropping emphatic "yes yes"
        if shortAudio && words.count >= 3 && Set(words).count == 1 {
            return true
        }
        
        // 3. Check for YouTube-style hallucinations (thank you for watching, subscribe)
        // F3: Tighten exact matches instead of substring contains to avoid over-filtering "I'm watching the kids"
        if words.count <= 8 {
            if words.starts(with: ["thank", "you", "so", "much"]) { return true }
            if words.starts(with: ["thank", "you", "for"]) { return true }
            if words.starts(with: ["thanks", "for"]) { return true }
            if words.starts(with: ["subscribe", "to", "my", "channel"]) { return true }
            if words.starts(with: ["subscribe", "to", "the", "channel"]) { return true }
            if words.starts(with: ["subscribe", "for", "more"]) { return true }
            if words.starts(with: ["please", "subscribe"]) { return true }
            if words.starts(with: ["like", "and", "subscribe"]) { return true }
            if words == ["i", "will", "see", "you", "in", "the", "next", "one"] { return true }
            if words == ["i", "ll", "see", "you", "in", "the", "next", "one"] { return true }
            if words == ["see", "you", "next", "time"] { return true }
        }
        
        return false
    }
}
