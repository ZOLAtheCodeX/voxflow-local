import XCTest
@testable import VoxFlowApp

private final class FakeTokenizer: WhisperTokenizerStub {}

/// Minimal WhisperTokenizer for tests: encodes each character as its
/// unicode scalar; injects one special token above specialTokenBegin.
class WhisperTokenizerStub: VocabularyTokenizing {
    var specialTokenThreshold: Int { 50_000 }
    func encodeText(_ text: String) -> [Int] {
        var tokens = text.unicodeScalars.map { Int($0.value) }
        tokens.append(50_257) // simulated special token appended by encoders
        return tokens
    }
}

/// R5.1: dictionary terms bias WhisperKit recognition via decoder prompt
/// tokens — "GDPR" should be recognized, not "gee dee pee are".
final class VocabularyBiasingTests: XCTestCase {

    func testHintFormatsAndCapsTerms() {
        let terms = (1...40).map { "term\($0)" }
        let hint = VocabularyBiasing.hint(terms: terms)
        XCTAssertTrue(hint.hasPrefix("Glossary: "))
        XCTAssertTrue(hint.contains("term24"))
        XCTAssertFalse(hint.contains("term25"), "vocabulary hint caps at 24 terms")
    }

    func testEmptyTermsYieldNoHint() {
        XCTAssertNil(VocabularyBiasing.promptTokens(terms: [], tokenizer: FakeTokenizer()))
    }

    func testPromptTokensFilterSpecialsAndCapLength() {
        let longTerms = (1...24).map { _ in String(repeating: "x", count: 30) }
        let tokens = VocabularyBiasing.promptTokens(terms: longTerms, tokenizer: FakeTokenizer())
        XCTAssertNotNil(tokens)
        XCTAssertLessThanOrEqual(tokens!.count, 100, "prompt budget capped — prompt tokens cost decode time")
        XCTAssertFalse(tokens!.contains { $0 >= 50_000 }, "special tokens must not leak into the prompt")
    }

    func testUniqueRightSideTermsFromDictionary() {
        let terms = VocabularyBiasing.terms(from: [
            DictionaryEntry(wrong: "gdpr", right: "GDPR", context: nil, learnedAt: Date()),
            DictionaryEntry(wrong: "g d p r", right: "GDPR", context: nil, learnedAt: Date()),
            DictionaryEntry(wrong: "hipaa", right: "HIPAA", context: nil, learnedAt: Date()),
        ])
        XCTAssertEqual(terms, ["GDPR", "HIPAA"], "dedupe rights, preserve order")
    }
}
