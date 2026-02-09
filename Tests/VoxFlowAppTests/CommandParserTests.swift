import XCTest
@testable import VoxFlowApp

final class CommandParserTests: XCTestCase {

    // MARK: - Workflow mode switching

    func testMeetingMode() {
        XCTAssertEqual(CommandParser.parse(from: "meeting mode"), .switchToMeeting)
    }

    func testTranslateMode() {
        XCTAssertEqual(CommandParser.parse(from: "translate mode"), .switchToTranslate)
    }

    func testTranslationMode() {
        XCTAssertEqual(CommandParser.parse(from: "translation mode"), .switchToTranslate)
    }

    func testDictationMode() {
        XCTAssertEqual(CommandParser.parse(from: "dictation mode"), .switchToDictation)
    }

    func testNormalMode() {
        XCTAssertEqual(CommandParser.parse(from: "normal mode"), .switchToDictation)
    }

    func testLocalMode() {
        XCTAssertEqual(CommandParser.parse(from: "local mode"), .switchToLocalProvider)
    }

    func testLocalProvider() {
        XCTAssertEqual(CommandParser.parse(from: "local provider"), .switchToLocalProvider)
    }

    func testPrivateAPI() {
        XCTAssertEqual(CommandParser.parse(from: "private api"), .switchToPrivateProvider)
    }

    func testAPIMode() {
        XCTAssertEqual(CommandParser.parse(from: "api mode"), .switchToPrivateProvider)
    }

    // MARK: - STT switching

    func testVoxtralSTT() {
        XCTAssertEqual(CommandParser.parse(from: "voxtral stt"), .switchToVoxtralSTT)
    }

    func testVoxtralSpeech() {
        XCTAssertEqual(CommandParser.parse(from: "voxtral speech"), .switchToVoxtralSTT)
    }

    func testWhisperSTT() {
        XCTAssertEqual(CommandParser.parse(from: "whisper stt"), .switchToWhisperSTT)
    }

    func testWhisperSpeech() {
        XCTAssertEqual(CommandParser.parse(from: "whisper speech"), .switchToWhisperSTT)
    }

    func testOpenAISTT() {
        XCTAssertEqual(CommandParser.parse(from: "openai stt"), .switchToOpenAISTT)
    }

    func testOpenAISpeech() {
        XCTAssertEqual(CommandParser.parse(from: "openai speech"), .switchToOpenAISTT)
    }

    // MARK: - Tone

    func testToneFormal() {
        XCTAssertEqual(CommandParser.parse(from: "tone formal"), .setTone(.formal))
    }

    func testFormalTone() {
        XCTAssertEqual(CommandParser.parse(from: "formal tone"), .setTone(.formal))
    }

    func testToneConcise() {
        XCTAssertEqual(CommandParser.parse(from: "tone concise"), .setTone(.concise))
    }

    func testConciseTone() {
        XCTAssertEqual(CommandParser.parse(from: "concise tone"), .setTone(.concise))
    }

    func testToneFriendly() {
        XCTAssertEqual(CommandParser.parse(from: "tone friendly"), .setTone(.friendly))
    }

    func testFriendlyTone() {
        XCTAssertEqual(CommandParser.parse(from: "friendly tone"), .setTone(.friendly))
    }

    func testToneNeutral() {
        XCTAssertEqual(CommandParser.parse(from: "tone neutral"), .setTone(.neutral))
    }

    func testNeutralTone() {
        XCTAssertEqual(CommandParser.parse(from: "neutral tone"), .setTone(.neutral))
    }

    // MARK: - Single-word commands

    func testApprove() {
        XCTAssertEqual(CommandParser.parse(from: "approve"), .approve)
    }

    func testInsert() {
        XCTAssertEqual(CommandParser.parse(from: "insert"), .insert)
    }

    func testCopy() {
        XCTAssertEqual(CommandParser.parse(from: "copy"), .copy)
    }

    func testRetry() {
        XCTAssertEqual(CommandParser.parse(from: "retry"), .retry)
    }

    func testUndo() {
        XCTAssertEqual(CommandParser.parse(from: "undo"), .undo)
    }

    func testBenchmark() {
        XCTAssertEqual(CommandParser.parse(from: "benchmark"), .runBenchmark)
    }

    // MARK: - Order independence

    func testModeMeetingReversed() {
        XCTAssertEqual(CommandParser.parse(from: "mode meeting"), .switchToMeeting)
    }

    // MARK: - Case insensitivity

    func testUppercaseMeetingMode() {
        XCTAssertEqual(CommandParser.parse(from: "MEETING MODE"), .switchToMeeting)
    }

    func testMixedCaseTranslateMode() {
        XCTAssertEqual(CommandParser.parse(from: "Translate Mode"), .switchToTranslate)
    }

    // MARK: - Unknown / empty / partial

    func testUnknownInput() {
        XCTAssertNil(CommandParser.parse(from: "hello world"))
    }

    func testEmptyString() {
        XCTAssertNil(CommandParser.parse(from: ""))
    }

    func testWhitespaceOnly() {
        XCTAssertNil(CommandParser.parse(from: "   "))
    }

    func testPartialMatchRejection() {
        // "meeting" alone should not match "meeting mode"
        XCTAssertNil(CommandParser.parse(from: "meeting"))
    }

    func testPartialModeAlone() {
        XCTAssertNil(CommandParser.parse(from: "mode"))
    }
}
