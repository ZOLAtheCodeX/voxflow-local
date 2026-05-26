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
}
