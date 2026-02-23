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

    // MARK: - Framing templates

    func testEmailFrameContainsSections() {
        let result = PromptFramingService.frame("tell the client we need to reschedule", intent: .email)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("Constraints:"), "Should contain Constraints section")
        XCTAssert(result.contains("Output format:"), "Should contain Output format section")
        XCTAssert(result.contains("tell the client we need to reschedule"), "Should contain original text")
    }

    func testCodeFrameContainsSections() {
        let result = PromptFramingService.frame("write a binary search function", intent: .code)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("Constraints:"), "Should contain Constraints section")
        XCTAssert(result.contains("write a binary search function"), "Should contain original text")
    }

    func testExplainFrameContainsTopic() {
        let result = PromptFramingService.frame("how dependency injection works", intent: .explain)
        XCTAssert(result.contains("Topic:"), "Should contain Topic section")
        XCTAssert(result.contains("how dependency injection works"), "Should contain original text")
    }

    func testCreativeFrameContainsSections() {
        let result = PromptFramingService.frame("a blog post about remote work", intent: .creative)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("a blog post about remote work"), "Should contain original text")
    }

    func testDataFrameContainsSections() {
        let result = PromptFramingService.frame("quarterly revenue trends", intent: .data)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("quarterly revenue trends"), "Should contain original text")
    }

    func testGeneralFrameIsMinimal() {
        let result = PromptFramingService.frame("help me think through this", intent: .general)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("help me think through this"), "Should contain original text")
        XCTAssertFalse(result.contains("Constraints:"), "General frame should be minimal")
    }
}
