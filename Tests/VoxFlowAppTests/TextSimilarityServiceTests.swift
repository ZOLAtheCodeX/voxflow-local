import XCTest
@testable import VoxFlowApp

final class TextSimilarityServiceTests: XCTestCase {

    func testExactMatch() {
        let score = TextSimilarityService.normalizedSimilarity(lhs: "hello", rhs: "hello")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testCaseInsensitivity() {
        let score = TextSimilarityService.normalizedSimilarity(lhs: "Hello", rhs: "hello")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testEmptyStrings() {
        let score = TextSimilarityService.normalizedSimilarity(lhs: "", rhs: "")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testOneEmptyString() {
        let score1 = TextSimilarityService.normalizedSimilarity(lhs: "hello", rhs: "")
        XCTAssertEqual(score1, 0.0, accuracy: 0.001)

        let score2 = TextSimilarityService.normalizedSimilarity(lhs: "", rhs: "hello")
        XCTAssertEqual(score2, 0.0, accuracy: 0.001)
    }

    func testCompletelyDifferentStrings() {
        let score = TextSimilarityService.normalizedSimilarity(lhs: "abc", rhs: "def")
        XCTAssertEqual(score, 0.0, accuracy: 0.001)
    }

    func testPartialMatch() {
        // "kitten" vs "sitting"
        // k -> s (sub)
        // i -> i (match)
        // t -> t (match)
        // t -> t (match)
        // e -> i (sub)
        // n -> n (match)
        // insertion of g at the end
        // Levenshtein distance is 3 (k->s, e->i, insert g).
        // Max length is 7 ("sitting").
        // Score = 1.0 - (3.0 / 7.0) = 4/7 approx 0.5714

        let score = TextSimilarityService.normalizedSimilarity(lhs: "kitten", rhs: "sitting")
        let expectedScore = 1.0 - (3.0 / 7.0)
        XCTAssertEqual(score, expectedScore, accuracy: 0.001)
    }

    func testUnicodeCharacters() {
        let score = TextSimilarityService.normalizedSimilarity(lhs: "café", rhs: "cafe")
        // "café" length 4. "cafe" length 4.
        // é vs e. Levenshtein distance 1.
        // Max length 4.
        // Score = 1.0 - (1.0 / 4.0) = 0.75
        XCTAssertEqual(score, 0.75, accuracy: 0.001)
    }

    func testEmoji() {
         let score = TextSimilarityService.normalizedSimilarity(lhs: "😀", rhs: "😃")
         // Distance 1. Max length 1.
         // Score 0.0
         XCTAssertEqual(score, 0.0, accuracy: 0.001)
    }

    func testSimilarPhrases() {
        let s1 = "The quick brown fox"
        let s2 = "The quick brown box"
        // Distance 1 (f -> b)
        // Length 19
        // Score = 1 - 1/19
        let score = TextSimilarityService.normalizedSimilarity(lhs: s1, rhs: s2)
        let expected = 1.0 - (1.0 / 19.0)
        XCTAssertEqual(score, expected, accuracy: 0.001)
    }
}
