import XCTest
@testable import VoxFlowApp

/// Per-mode cleanup provenance on the candidate so a LATER review-mode insert
/// (the user toggles light/polish then clicks Insert) can stamp the audit
/// receipt with what actually produced the selected mode's text.
final class TranscriptCandidateProvenanceTests: XCTestCase {

    func testProvenanceForModeReturnsPerModeValue() {
        let candidate = TranscriptCandidate(
            rawText: "r", lightText: "l", polishText: "p", selectedMode: .polish,
            lightProvenance: "rules", polishProvenance: "gemma4:e2b-mlx")
        XCTAssertEqual(candidate.provenance(for: .light), "rules")
        XCTAssertEqual(candidate.provenance(for: .polish), "gemma4:e2b-mlx")
        // Raw is verbatim transcription — it has no cleanup provenance.
        XCTAssertNil(candidate.provenance(for: .raw))
    }

    func testProvenanceDefaultsNilWhenUnset() {
        let candidate = TranscriptCandidate(
            rawText: "r", lightText: "l", polishText: "p", selectedMode: .light)
        XCTAssertNil(candidate.provenance(for: .light))
        XCTAssertNil(candidate.provenance(for: .polish))
    }
}
