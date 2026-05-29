import Foundation

enum HallucinationFilter {
    private static let singleWordHallucinations: Set<String> = [
        "hello", "hi", "hey", "bye", "goodbye", "you", "thanks", "yeah", "yes", "okay", "ok"
    ]
    
    private static let multiWordTriggers: Set<String> = [
        "subscribe", "watching", "channel"
    ]

    static func isLikelyHallucination(_ text: String, shortAudio: Bool) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return true }
        
        if stripped.hasPrefix("[") || stripped.hasPrefix("(") || stripped.hasPrefix("*") {
            let lowered = stripped.lowercased()
            if lowered.contains("typing") || lowered.contains("clack") || lowered.contains("keyboard") || lowered.contains("silence") || lowered.contains("noise") {
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
            if words.allSatisfy({ singleWordHallucinations.contains($0) }) {
                return true
            }
            // "thank you"
            if words == ["thank", "you"] { return true }
            // "hello everyone", "hi guys", etc
            if words[0] == "hello" || words[0] == "hi" { return true }
        }
        
        // 2. Check for repeats (e.g. "hello. hello, hello!")
        // Since we stripped punctuation, Set(words) is perfectly accurate
        if Set(words).count == 1 {
            return true
        }
        
        // 3. Check for YouTube-style hallucinations (thank you for watching, subscribe)
        if words.count <= 8 {
            if !multiWordTriggers.isDisjoint(with: Set(words)) {
                return true
            }
            if words.starts(with: ["thank", "you", "so", "much"]) { return true }
            if words.starts(with: ["thank", "you", "for"]) { return true }
            if words == ["i", "will", "see", "you", "in", "the", "next", "one"] { return true }
            if words == ["i", "ll", "see", "you", "in", "the", "next", "one"] { return true }
            if words == ["see", "you", "next", "time"] { return true }
        }
        
        return false
    }
}
