import XCTest
@testable import VoxFlowApp

/// Parity contract with backend `WhisperEngine._estimate_confidence`
/// (backend/app/engines/whisper.py): coverage-based estimate, lone-word
/// penalty on long audio, plus the WhisperKit-only noSpeechProb cap.
final class TranscriptionConfidenceTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double, noSpeech: Double = 0.0) -> TranscriptionConfidence.SegmentSignal {
        TranscriptionConfidence.SegmentSignal(startSeconds: start, endSeconds: end, noSpeechProb: noSpeech)
    }

    func testEmptyTextReturnsZero() {
        XCTAssertEqual(
            TranscriptionConfidence.estimate(segments: [], text: "", audioDurationSeconds: 5.0),
            0.0
        )
    }

    func testFullCoverageSpeechScoresHigh() {
        let conf = TranscriptionConfidence.estimate(
            segments: [segment(0.2, 3.8)],
            text: "I need to schedule a meeting for tomorrow",
            audioDurationSeconds: 4.0
        )
        XCTAssertGreaterThanOrEqual(conf, 0.8, "Full-coverage speech should score high, got \(conf)")
    }

    func testLoneWordFromLongNoiseIsCrushed() {
        // "hello" with a 0.4s segment from 5s of noise — the ghost signature.
        let conf = TranscriptionConfidence.estimate(
            segments: [segment(0.0, 0.4)],
            text: "hello",
            audioDurationSeconds: 5.0
        )
        XCTAssertLessThanOrEqual(conf, 0.1, "Hallucinated lone word from long audio must be <= 0.1, got \(conf)")
    }

    func testTwoWordsFromLongNoiseIsCrushed() {
        // "hello world" from 6s of noise — multi-word ghost that the old
        // exp(avgLogprob) estimate scored 0.3-0.6.
        let conf = TranscriptionConfidence.estimate(
            segments: [segment(0.0, 0.7)],
            text: "hello world",
            audioDurationSeconds: 6.0
        )
        XCTAssertLessThanOrEqual(conf, 0.1, "Two-word ghost from long audio must be <= 0.1, got \(conf)")
    }

    func testLegitimateSingleWordWithStrongCoverageSurvives() {
        // Real "yes" spoken for 1.1s in a 3s clip — coverage ≈ 0.37.
        let conf = TranscriptionConfidence.estimate(
            segments: [segment(0.5, 1.6)],
            text: "yes",
            audioDurationSeconds: 3.0
        )
        XCTAssertGreaterThan(conf, 0.15, "Legit single word with strong coverage should survive, got \(conf)")
    }

    func testNoSegmentsFallsBackToWordRate() {
        // 10 words from 4s — ~2.5 words/s, plausible dictation.
        let conf = TranscriptionConfidence.estimate(
            segments: [],
            text: "one two three four five six seven eight nine ten",
            audioDurationSeconds: 4.0
        )
        XCTAssertGreaterThanOrEqual(conf, 0.8, "Word-rate fallback should score plausible speech high, got \(conf)")
    }

    func testHighNoSpeechProbCapsConfidence() {
        // Good apparent coverage but the model itself says "probably not speech".
        let conf = TranscriptionConfidence.estimate(
            segments: [segment(0.0, 3.5, noSpeech: 0.8)],
            text: "thank you very much everyone",
            audioDurationSeconds: 4.0
        )
        XCTAssertLessThanOrEqual(conf, 0.1, "Mean noSpeechProb > 0.5 must cap confidence, got \(conf)")
    }

    func testConfidenceNeverExceedsCap() {
        let conf = TranscriptionConfidence.estimate(
            segments: [segment(0.0, 4.0)],
            text: "a b c d e f g h i j k l m n o p",
            audioDurationSeconds: 4.0
        )
        XCTAssertLessThanOrEqual(conf, 0.95)
    }
}
