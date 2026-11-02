import AppKit
import XCTest
@testable import VoxFlowApp

/// The pill's outcome after a capture. A wrong outcome ("Not inserted" when
/// the text landed) is worse than none, so every branch of the
/// classification order is pinned here (spec amendment 1).
final class PillOutcomeTests: XCTestCase {

    // MARK: - Classification order

    func test_failed_insert_is_not_inserted_with_the_status_line() {
        XCTAssertEqual(
            PillOutcome.classify(finalState: .idle, insertSucceeded: false, statusLine: "Auto-insert failed, copied to clipboard"),
            .notInserted(message: "Auto-insert failed, copied to clipboard")
        )
    }

    func test_failure_wins_over_review() {
        XCTAssertEqual(
            PillOutcome.classify(finalState: .review, insertSucceeded: false, statusLine: "Insert failed. Copied to clipboard."),
            .notInserted(message: "Insert failed. Copied to clipboard.")
        )
    }

    func test_successful_insert_is_inserted() {
        XCTAssertEqual(
            PillOutcome.classify(finalState: .idle, insertSucceeded: true, statusLine: "Inserted (raw, Notes)"),
            .inserted
        )
    }

    func test_success_wins_over_review() {
        XCTAssertEqual(PillOutcome.classify(finalState: .review, insertSucceeded: true, statusLine: "Inserted"), .inserted)
    }

    /// Every path to `.error` ends with nothing inserted, so it keeps the
    /// warning styling rather than the neutral status.
    func test_error_ending_is_not_inserted_with_the_status_line() {
        XCTAssertEqual(
            PillOutcome.classify(finalState: .error, insertSucceeded: nil, statusLine: "Error. Retry capture."),
            .notInserted(message: "Error. Retry capture.")
        )
    }

    func test_insert_result_wins_over_error() {
        XCTAssertEqual(PillOutcome.classify(finalState: .error, insertSucceeded: true, statusLine: "x"), .inserted)
        XCTAssertEqual(
            PillOutcome.classify(finalState: .error, insertSucceeded: false, statusLine: "Insert failed"),
            .notInserted(message: "Insert failed")
        )
    }

    func test_review_without_an_insert_is_ready_to_review() {
        XCTAssertEqual(PillOutcome.classify(finalState: .review, insertSucceeded: nil, statusLine: "Review ready"), .readyToReview)
    }

    /// Review Focus 2: built-in voice actions and voice-control commands end
    /// without inserting by design. They show the status line, neutral.
    func test_voice_action_shows_the_status_line_never_not_inserted() {
        XCTAssertEqual(
            PillOutcome.classify(finalState: .idle, insertSucceeded: nil, statusLine: "Voice action: new tab"),
            .status(message: "Voice action: new tab")
        )
    }

    func test_reject_shows_the_status_line() {
        XCTAssertEqual(
            PillOutcome.classify(finalState: .idle, insertSucceeded: nil, statusLine: "No speech detected (audio kept)"),
            .status(message: "No speech detected (audio kept)")
        )
    }

    func test_empty_status_line_shows_nothing() {
        XCTAssertNil(PillOutcome.classify(finalState: .idle, insertSucceeded: nil, statusLine: ""))
        XCTAssertNil(PillOutcome.classify(finalState: .idle, insertSucceeded: nil, statusLine: "   "))
    }

    // MARK: - Announcements

    func test_announcements() {
        XCTAssertEqual(PillOutcome.inserted.announcement, "Inserted")
        XCTAssertEqual(PillOutcome.readyToReview.announcement, "Ready to review")
        XCTAssertEqual(
            PillOutcome.notInserted(message: "Insert failed. Copied to clipboard.").announcement,
            "Not inserted. Insert failed. Copied to clipboard."
        )
        XCTAssertEqual(PillOutcome.notInserted(message: "").announcement, "Not inserted")
        XCTAssertEqual(PillOutcome.status(message: "Voice action: new tab").announcement, "Voice action: new tab")
    }

    // MARK: - Badge

    func test_badge_uses_the_status_vocabulary() {
        XCTAssertEqual(PillOutcome.inserted.badgeStatus, VFStatus(.ready, "Inserted"))
        XCTAssertEqual(PillOutcome.readyToReview.badgeStatus, VFStatus(.review, "Ready to review"))
        // A failed insert keeps the warning styling and shows the status line itself.
        XCTAssertEqual(
            PillOutcome.notInserted(message: "Insert failed. Copied to clipboard.").badgeStatus,
            VFStatus(.attention, "Insert failed. Copied to clipboard.")
        )
        XCTAssertEqual(PillOutcome.notInserted(message: "").badgeStatus, VFStatus(.attention, "Not inserted"))
        // Everything else is neutral information, never a failure.
        let status = PillOutcome.status(message: "Voice action: new tab").badgeStatus
        XCTAssertEqual(status, VFStatus(.info, "Voice action: new tab"))
        XCTAssertEqual(status.symbol, "info.circle")
    }

    // MARK: - Size

    /// Review Focus 5: a 300-character status line never widens the pill past 360 pt.
    func test_long_status_line_caps_the_pill_at_360() {
        let size = RecordingOverlayController.pillSize(for: .status(message: String(repeating: "x", count: 300)))
        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, 32)
    }

    func test_pill_size_default_is_220_by_32() {
        XCTAssertEqual(RecordingOverlayController.pillSize(for: nil), NSSize(width: 220, height: 32))
        XCTAssertEqual(RecordingOverlayController.pillSize(for: .inserted), NSSize(width: 220, height: 32))
        XCTAssertEqual(RecordingOverlayController.pillSize(for: .readyToReview), NSSize(width: 220, height: 32))
    }

    func test_message_outcomes_widen_to_360() {
        XCTAssertEqual(RecordingOverlayController.pillSize(for: .notInserted(message: "x")), NSSize(width: 360, height: 32))
        XCTAssertEqual(RecordingOverlayController.pillSize(for: .status(message: "x")), NSSize(width: 360, height: 32))
    }
}
