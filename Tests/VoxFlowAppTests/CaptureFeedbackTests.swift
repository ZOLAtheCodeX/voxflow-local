import XCTest
@testable import VoxFlowApp

/// `CaptureFeedback` splits the ambiguous "nothing usable came back" outcome
/// into "you were silent / your mic is dead" vs "your mic input is too weak". An
/// empty/low-confidence transcript from above-silence audio — or a dead-air
/// capture — is almost always a microphone problem the user can act on, not a
/// sign they said nothing.
final class CaptureFeedbackTests: XCTestCase {

    func testEmptyWithWeakInputPromptsMicCheck() {
        let status = CaptureFeedback.rejectionStatus(reason: .empty, rmsEnergy: 0.005)
        XCTAssertTrue(status.lowercased().contains("mic"), "weak-input empty should point at the microphone, got: \(status)")
    }

    func testLowConfidenceWithWeakInputPromptsMicCheck() {
        let status = CaptureFeedback.rejectionStatus(reason: .lowConfidence, rmsEnergy: 0.004)
        XCTAssertTrue(status.lowercased().contains("mic"), "weak-input low-confidence should point at the microphone, got: \(status)")
    }

    func testEmptyWithHealthyInputStaysGeneric() {
        let status = CaptureFeedback.rejectionStatus(reason: .empty, rmsEnergy: 0.08)
        XCTAssertFalse(status.lowercased().contains("mic"), "healthy-level empty should not blame the mic, got: \(status)")
        XCTAssertTrue(status.lowercased().contains("no speech"))
    }

    func testSilenceWithDeadMicPromptsMicCheck() {
        // A fully dead/near-zero-RMS capture is the STRONGEST "check your input"
        // case, so it must get the actionable mic hint, not the generic message.
        let status = CaptureFeedback.rejectionStatus(reason: .silence, rmsEnergy: 0.001)
        XCTAssertTrue(status.lowercased().contains("mic"), "dead-mic silence should point at the microphone, got: \(status)")
    }

    func testHallucinationRejectionNeverBlamesMicEvenWhenWeak() {
        // A phrase the hallucination filter caught is content the model invented;
        // input level is irrelevant, so don't send the user chasing their mic.
        let status = CaptureFeedback.rejectionStatus(reason: .hallucinationFilter, rmsEnergy: 0.001)
        XCTAssertFalse(status.lowercased().contains("mic"))
    }

    func testPlaceholderNeverBlamesMic() {
        let status = CaptureFeedback.rejectionStatus(reason: .placeholder, rmsEnergy: 0.001)
        XCTAssertFalse(status.lowercased().contains("mic"))
    }

    func testBoundaryAtSpeechFloor() {
        // Exactly at the speech floor counts as healthy; just under counts as weak.
        XCTAssertFalse(
            CaptureFeedback.rejectionStatus(reason: .empty, rmsEnergy: CapturedAudio.speechFloor).lowercased().contains("mic"))
        XCTAssertTrue(
            CaptureFeedback.rejectionStatus(reason: .empty, rmsEnergy: CapturedAudio.speechFloor - 0.001).lowercased().contains("mic"))
    }
}

// ── VAD-refined feedback (R6) ────────────────────────────────────────────

extension CaptureFeedbackTests {
    /// Silero diagnosis (via /v1/audio/diagnose) sharpens the empty-capture
    /// message beyond the RMS heuristic: "speech but too quiet" vs "only
    /// background noise" vs "speech but not recognized".

    func test_refined_speech_too_quiet() {
        let d = AudioDiagnosis(speechDetected: true, speechMs: 1200, vadAvailable: true)
        let status = CaptureFeedback.refinedRejectionStatus(reason: .empty, rmsEnergy: 0.012, diagnosis: d)
        XCTAssertTrue(status.contains("too quiet"), "weak speech must earn the raise-input hint: \(status)")
        XCTAssertTrue(status.contains("System Settings"), "hint must stay actionable: \(status)")
    }

    func test_refined_speech_at_normal_level_not_recognized() {
        let d = AudioDiagnosis(speechDetected: true, speechMs: 900, vadAvailable: true)
        let status = CaptureFeedback.refinedRejectionStatus(reason: .empty, rmsEnergy: 0.08, diagnosis: d)
        XCTAssertFalse(status.contains("too quiet"), "normal-level speech must not blame the mic: \(status)")
        XCTAssertTrue(status.lowercased().contains("not recognized"), "\(status)")
    }

    func test_refined_no_speech_names_background_noise() {
        let d = AudioDiagnosis(speechDetected: false, speechMs: 0, vadAvailable: true)
        let status = CaptureFeedback.refinedRejectionStatus(reason: .empty, rmsEnergy: 0.03, diagnosis: d)
        XCTAssertTrue(status.lowercased().contains("background noise"), "\(status)")
    }

    func test_refined_falls_back_when_vad_unavailable() {
        let d = AudioDiagnosis(speechDetected: true, speechMs: 0, vadAvailable: false)
        let fallback = CaptureFeedback.rejectionStatus(reason: .empty, rmsEnergy: 0.012)
        XCTAssertEqual(
            CaptureFeedback.refinedRejectionStatus(reason: .empty, rmsEnergy: 0.012, diagnosis: d),
            fallback, "fail-open diagnosis must not change the message")
    }

    func test_refined_falls_back_without_diagnosis() {
        let fallback = CaptureFeedback.rejectionStatus(reason: .empty, rmsEnergy: 0.012)
        XCTAssertEqual(
            CaptureFeedback.refinedRejectionStatus(reason: .empty, rmsEnergy: 0.012, diagnosis: nil),
            fallback)
    }

    func test_refined_ignores_invented_content_rejections() {
        // Hallucination/placeholder rejections are about model-invented
        // content — a speech-presence diagnosis is irrelevant there.
        let d = AudioDiagnosis(speechDetected: true, speechMs: 1000, vadAvailable: true)
        let fallback = CaptureFeedback.rejectionStatus(reason: .hallucinationFilter, rmsEnergy: 0.03)
        XCTAssertEqual(
            CaptureFeedback.refinedRejectionStatus(reason: .hallucinationFilter, rmsEnergy: 0.03, diagnosis: d),
            fallback)
    }
}
