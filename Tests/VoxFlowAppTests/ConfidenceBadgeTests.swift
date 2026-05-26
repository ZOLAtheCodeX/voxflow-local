import XCTest
@testable import VoxFlowApp

@MainActor
final class ConfidenceBadgeTests: XCTestCase {

    func testTranscriptCandidateStoresConfidence() {
        let candidate = TranscriptCandidate(
            rawText: "hello world",
            lightText: "Hello world.",
            polishText: "Hello, world.",
            selectedMode: .raw,
            confidence: 0.85
        )
        XCTAssertEqual(candidate.confidence, 0.85, accuracy: 0.001)
    }

    func testTranscriptCandidateDefaultConfidenceIsZero() {
        let candidate = TranscriptCandidate(
            rawText: "test",
            lightText: "test",
            polishText: "test",
            selectedMode: .raw
        )
        XCTAssertEqual(candidate.confidence, 0.0, accuracy: 0.001)
    }

    // Phase 4: ConfidenceBadge now pulls its colors from VF semantic tokens
    // so the design system controls the success/warning/error palette.
    // .yellow → VF.colorWarning (.orange) is intentional — Apple's HIG uses
    // orange for warnings, yellow is reserved for highlights.
    func testConfidenceBadgeSuccessAboveThreshold() {
        let badge = ConfidenceBadge(confidence: 0.85)
        XCTAssertEqual(badge.color, VF.colorSuccess)
    }

    func testConfidenceBadgeSuccessAtBoundary() {
        let badge = ConfidenceBadge(confidence: 0.7)
        XCTAssertEqual(badge.color, VF.colorSuccess)
    }

    func testConfidenceBadgeWarningRange() {
        let badge = ConfidenceBadge(confidence: 0.5)
        XCTAssertEqual(badge.color, VF.colorWarning)
    }

    func testConfidenceBadgeWarningAtBoundary() {
        let badge = ConfidenceBadge(confidence: 0.4)
        XCTAssertEqual(badge.color, VF.colorWarning)
    }

    func testConfidenceBadgeErrorBelowThreshold() {
        let badge = ConfidenceBadge(confidence: 0.3)
        XCTAssertEqual(badge.color, VF.colorError)
    }

    func testConfidenceBadgeErrorAtZero() {
        let badge = ConfidenceBadge(confidence: 0.0)
        XCTAssertEqual(badge.color, VF.colorError)
    }
}
