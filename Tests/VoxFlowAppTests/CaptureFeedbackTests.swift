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
