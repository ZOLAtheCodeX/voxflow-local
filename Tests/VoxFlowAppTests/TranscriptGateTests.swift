import XCTest
@testable import VoxFlowApp

/// Single gate every transcript must pass before it can reach insertion,
/// the cockpit transcript, or the command lane. Previously these checks
/// lived inline in AppCoordinator only — the cockpit chunk path bypassed
/// them entirely (ghost-hello cause #5, 2026-06-11 audit).
final class TranscriptGateTests: XCTestCase {

    func testEmptyTextRejected() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "   ", confidence: 0.9, audioDurationSeconds: 2.0),
            .rejected(reason: .empty)
        )
    }

    func testPlaceholderRejected() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "[transcription unavailable: no audio captured]", confidence: 0.9, audioDurationSeconds: 2.0),
            .rejected(reason: .placeholder)
        )
    }

    func testHallucinationFilterApplies() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "Hello.", confidence: 0.9, audioDurationSeconds: 1.0),
            .rejected(reason: .hallucinationFilter)
        )
    }

    func testShortAudioThresholdAt3Seconds() {
        // "thank you" is short-only filtered: rejected under 3s, accepted at 3s+.
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "thank you", confidence: 0.9, audioDurationSeconds: 2.9),
            .rejected(reason: .hallucinationFilter)
        )
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "thank you", confidence: 0.9, audioDurationSeconds: 3.1),
            .accepted
        )
    }

    func testLoneWordLowConfidenceRejected() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "world", confidence: 0.1, audioDurationSeconds: 5.0),
            .rejected(reason: .lowConfidence)
        )
    }

    func testGhostSignatureRejected() {
        // Multi-word hallucination from long noise whose coverage confidence
        // collapsed — the exact pattern the old inline gate never caught
        // (it only gated 1-word results on long audio).
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "hello world", confidence: 0.1, audioDurationSeconds: 5.0),
            .rejected(reason: .lowConfidence)
        )
    }

    func testShortRealDictationAccepted() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "send it", confidence: 0.6, audioDurationSeconds: 1.2),
            .accepted
        )
    }

    func testNormalDictationAccepted() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "Schedule a team sync for Thursday at 2 PM", confidence: 0.85, audioDurationSeconds: 4.0),
            .accepted
        )
    }

    func testLongTextLowConfidenceStillAccepted() {
        // The confidence gate exists for short outputs from long audio; a full
        // sentence is never discarded on confidence alone.
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "please update the quarterly report with the new figures", confidence: 0.05, audioDurationSeconds: 6.0),
            .accepted
        )
    }

    func testLoneRealWordWithDecentConfidenceAccepted() {
        XCTAssertEqual(
            TranscriptGate.evaluate(text: "Approved", confidence: 0.5, audioDurationSeconds: 0.8),
            .accepted
        )
    }
}
