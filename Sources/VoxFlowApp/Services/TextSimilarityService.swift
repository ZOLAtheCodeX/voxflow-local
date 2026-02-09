import Foundation

struct TextSimilarityService {
    static func normalizedSimilarity(lhs: String, rhs: String) -> Double {
        let a = Array(lhs.lowercased())
        let b = Array(rhs.lowercased())

        if a.isEmpty && b.isEmpty {
            return 1.0
        }

        let distance = levenshtein(a, b)
        let maxLength = max(a.count, b.count)
        guard maxLength > 0 else { return 1.0 }

        let score = 1.0 - (Double(distance) / Double(maxLength))
        return min(1.0, max(0.0, score))
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)

        for (i, leftChar) in lhs.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(rhs.count + 1)

            for (j, rightChar) in rhs.enumerated() {
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let substitution = previous[j] + (leftChar == rightChar ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }

            previous = current
        }

        return previous[rhs.count]
    }
}
