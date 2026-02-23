import XCTest
@testable import VoxFlowApp

final class PromptFramingServiceTests: XCTestCase {

    // MARK: - Intent detection — canonical phrases

    func testEmailIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("write an email to my manager declining the meeting"), .email)
    }

    func testEmailIntentDraft() {
        XCTAssertEqual(PromptFramingService.detectIntent("draft a reply to the client"), .email)
    }

    func testCodeIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("write a function that sorts an array"), .code)
    }

    func testCodeIntentDebug() {
        XCTAssertEqual(PromptFramingService.detectIntent("debug this API endpoint"), .code)
    }

    func testExplainIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("explain how dependency injection works"), .explain)
    }

    func testExplainIntentWhatIs() {
        XCTAssertEqual(PromptFramingService.detectIntent("what is a monad in functional programming"), .explain)
    }

    func testCreativeIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("write a blog post about remote work productivity"), .creative)
    }

    func testCreativeIntentTweet() {
        XCTAssertEqual(PromptFramingService.detectIntent("draft a tweet announcing our product launch"), .creative)
    }

    func testDataIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("summarize the quarterly revenue numbers"), .data)
    }

    func testDataIntentCompare() {
        XCTAssertEqual(PromptFramingService.detectIntent("compare the differences between React and Vue"), .data)
    }

    func testGeneralFallback() {
        XCTAssertEqual(PromptFramingService.detectIntent("help me think through this problem"), .general)
    }

    func testEmptyStringFallback() {
        XCTAssertEqual(PromptFramingService.detectIntent(""), .general)
    }

    // MARK: - Intent detection — priority / disambiguation

    func testCodeBeatsCreativeForReview() {
        XCTAssertEqual(PromptFramingService.detectIntent("review this pull request"), .code)
    }

    func testCreativePostNotDataPost() {
        XCTAssertEqual(PromptFramingService.detectIntent("write a post about machine learning trends"), .creative)
    }
}
