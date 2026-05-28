import XCTest
@testable import VoxFlowApp

final class VoiceCommandRouterTests: XCTestCase {

    // MARK: - Action keywords

    func test_action_keywords_match() {
        XCTAssertEqual(VoiceCommandRouter.parse("memo"), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("MECE"), .action(.mece))
        XCTAssertEqual(VoiceCommandRouter.parse("items"), .action(.items))
        XCTAssertEqual(VoiceCommandRouter.parse("steel"), .action(.steel))
        XCTAssertEqual(VoiceCommandRouter.parse("Pyramid"), .action(.pyramid))
        XCTAssertEqual(VoiceCommandRouter.parse("disclaimer"), .action(.disclaimer))
    }

    // MARK: - Meta keywords

    func test_meta_keywords_match() {
        XCTAssertEqual(VoiceCommandRouter.parse("undo"), .undo)
        XCTAssertEqual(VoiceCommandRouter.parse("cancel"), .cancel)
        XCTAssertEqual(VoiceCommandRouter.parse("insert"), .insert)
        XCTAssertEqual(VoiceCommandRouter.parse("copy"), .copy)
    }

    // MARK: - Normalisation

    func test_case_insensitive() {
        XCTAssertEqual(VoiceCommandRouter.parse("MEMO"), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("Memo"), .action(.memo))
    }

    func test_trailing_punctuation_stripped() {
        XCTAssertEqual(VoiceCommandRouter.parse("memo."), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("memo!"), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("memo?"), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse(" memo "), .action(.memo))
    }

    // MARK: - Rejections

    func test_multi_word_is_not_command() {
        XCTAssertEqual(VoiceCommandRouter.parse("memo and then mece"), .none)
        XCTAssertEqual(VoiceCommandRouter.parse("send the memo"), .none)
    }

    func test_unknown_word_is_not_command() {
        XCTAssertEqual(VoiceCommandRouter.parse("hello"), .none)
        XCTAssertEqual(VoiceCommandRouter.parse("foobar"), .none)
    }

    func test_empty_input_returns_none() {
        XCTAssertEqual(VoiceCommandRouter.parse(""), .none)
        XCTAssertEqual(VoiceCommandRouter.parse("   "), .none)
        XCTAssertEqual(VoiceCommandRouter.parse("..."), .none)
    }

    // MARK: - resolveSnippet — scope gating

    func test_resolveSnippet_global_matches_any_context() {
        let s = VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertEqual(
            VoiceCommandRouter.resolveSnippet("signoff", snippets: [s], context: .longFormOnly)?.keyword,
            "signoff")
        XCTAssertEqual(
            VoiceCommandRouter.resolveSnippet("signoff", snippets: [s], context: .quickOnly)?.keyword,
            "signoff")
    }

    func test_resolveSnippet_longFormOnly_gated() {
        let s = VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .longFormOnly, createdAt: Date())
        XCTAssertEqual(
            VoiceCommandRouter.resolveSnippet("signoff", snippets: [s], context: .longFormOnly)?.keyword,
            "signoff")
        XCTAssertNil(VoiceCommandRouter.resolveSnippet("signoff", snippets: [s], context: .quickOnly))
    }

    func test_resolveSnippet_quickOnly_gated() {
        let s = VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .quickOnly, createdAt: Date())
        XCTAssertEqual(
            VoiceCommandRouter.resolveSnippet("signoff", snippets: [s], context: .quickOnly)?.keyword,
            "signoff")
        XCTAssertNil(VoiceCommandRouter.resolveSnippet("signoff", snippets: [s], context: .longFormOnly))
    }

    // MARK: - resolveSnippet — precedence

    func test_resolveSnippet_meta_word_never_resolves() {
        let s = VoiceSnippet(keyword: "cancel", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertNil(VoiceCommandRouter.resolveSnippet("cancel", snippets: [s], context: .longFormOnly))
        XCTAssertEqual(VoiceCommandRouter.parse("cancel"), .cancel)
    }

    func test_resolveSnippet_action_word_never_resolves() {
        let s = VoiceSnippet(keyword: "memo", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertNil(VoiceCommandRouter.resolveSnippet("memo", snippets: [s], context: .longFormOnly))
        XCTAssertEqual(VoiceCommandRouter.parse("memo"), .action(.memo))
    }

    // MARK: - resolveSnippet — normalization

    func test_resolveSnippet_case_insensitive_and_punctuation() {
        let s = VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertEqual(
            VoiceCommandRouter.resolveSnippet("SignOff.", snippets: [s], context: .longFormOnly)?.keyword,
            "signoff")
    }

    func test_resolveSnippet_multiword_input_returns_nil() {
        let s = VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertNil(VoiceCommandRouter.resolveSnippet("two words", snippets: [s], context: .global))
    }

    func test_resolveSnippet_no_match_returns_nil() {
        let s = VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertNil(VoiceCommandRouter.resolveSnippet("nothere", snippets: [s], context: .longFormOnly))
    }

    // Proves store↔router parity: a keyword stored via the shared normalizer (which strips
    // boundary punctuation) resolves for the equivalently-normalized spoken word.
    func test_resolveSnippet_matches_when_keyword_had_trailing_punctuation() {
        let s = VoiceSnippet(keyword: "sign", text: "Best regards", scope: .global, createdAt: Date())
        XCTAssertEqual(
            VoiceCommandRouter.resolveSnippet("sign.", snippets: [s], context: .longFormOnly)?.keyword,
            "sign")
    }

    // MARK: - Regression guard for parse()

    func test_existing_parse_keywords_unchanged() {
        XCTAssertEqual(VoiceCommandRouter.parse("memo"), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("undo"), .undo)
        XCTAssertEqual(VoiceCommandRouter.parse("cancel"), .cancel)
        XCTAssertEqual(VoiceCommandRouter.parse("insert"), .insert)
        XCTAssertEqual(VoiceCommandRouter.parse("copy"), .copy)
        XCTAssertEqual(VoiceCommandRouter.parse("disclaimer"), .action(.disclaimer))
        XCTAssertEqual(VoiceCommandRouter.parse("hello world"), .none)
    }
}
