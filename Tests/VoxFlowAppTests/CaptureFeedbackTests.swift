import XCTest
@testable import VoxFlowApp

/// `CaptureFeedback` splits the ambiguous "nothing usable came back" outcome
/// into "you were silent" vs "your mic input is too weak". An empty transcript
/// from several seconds of above-silence audio is almost always a microphone
/// input problem the user can act on, not a sign they said nothing.
final class CaptureFeedbackTests: XCTestCase {

    func testEmptyWithWeakInputPromptsMicCheck() {
        let status = CaptureFeedback.rejectionStatus(reason: "empty", rmsEnergy: 0.005)
        XCTAssertTrue(status.lowercased().contains("mic"), "weak-input empty should point at the microphone, got: \(status)")
    }

    func testLowConfidenceWithWeakInputPromptsMicCheck() {
        let status = CaptureFeedback.rejectionStatus(reason: "low_confidence", rmsEnergy: 0.004)
        XCTAssertTrue(status.lowercased().contains("mic"), "weak-input low_confidence should point at the microphone, got: \(status)")
    }

    func testEmptyWithHealthyInputStaysGeneric() {
        let status = CaptureFeedback.rejectionStatus(reason: "empty", rmsEnergy: 0.08)
        XCTAssertFalse(status.lowercased().contains("mic"), "healthy-level empty should not blame the mic, got: \(status)")
        XCTAssertTrue(status.lowercased().contains("no speech"))
    }

    func testHallucinationRejectionNeverBlamesMicEvenWhenWeak() {
        // A phrase the hallucination filter caught is content the model invented;
        // input level is irrelevant, so don't send the user chasing their mic.
        let status = CaptureFeedback.rejectionStatus(reason: "hallucination_filter", rmsEnergy: 0.001)
        XCTAssertFalse(status.lowercased().contains("mic"))
    }

    func testBoundaryAtWeakInputCeiling() {
        // Exactly at the ceiling counts as healthy; just under counts as weak.
        XCTAssertFalse(
            CaptureFeedback.rejectionStatus(reason: "empty", rmsEnergy: CaptureFeedback.weakInputCeiling).lowercased().contains("mic"))
        XCTAssertTrue(
            CaptureFeedback.rejectionStatus(reason: "empty", rmsEnergy: CaptureFeedback.weakInputCeiling - 0.001).lowercased().contains("mic"))
    }
}
