import XCTest
@testable import VoxFlowApp

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

    func testConfidenceBadgeGreenThreshold() {
        let badge = ConfidenceBadge(confidence: 0.85)
        XCTAssertEqual(badge.color, .green)
    }

    func testConfidenceBadgeGreenAtBoundary() {
        let badge = ConfidenceBadge(confidence: 0.7)
        XCTAssertEqual(badge.color, .green)
    }

    func testConfidenceBadgeYellowRange() {
        let badge = ConfidenceBadge(confidence: 0.5)
        XCTAssertEqual(badge.color, .yellow)
    }

    func testConfidenceBadgeYellowAtBoundary() {
        let badge = ConfidenceBadge(confidence: 0.4)
        XCTAssertEqual(badge.color, .yellow)
    }

    func testConfidenceBadgeRedBelowThreshold() {
        let badge = ConfidenceBadge(confidence: 0.3)
        XCTAssertEqual(badge.color, .red)
    }

    func testConfidenceBadgeRedAtZero() {
        let badge = ConfidenceBadge(confidence: 0.0)
        XCTAssertEqual(badge.color, .red)
    }
}
