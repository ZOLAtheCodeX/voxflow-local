import XCTest
@testable import VoxFlowApp

/// Which palette controls each session state exposes.
final class PaletteStateRulesTests: XCTestCase {

    // MARK: - Options row (ruling R18)

    /// The Cleanup, Tone and ••• menus are disabled while a capture is in
    /// flight: the old palette never showed them then, and the workflow Mode
    /// picker clears candidates and restarts the backend.
    func test_options_row_is_interactive_only_outside_a_capture() {
        let expected: [SessionState: Bool] = [
            .idle: true,
            .recording: false,
            .transcribing: false,
            .review: true,
            .inserting: false,
            .onboarding: true,
            .error: true,
        ]
        XCTAssertEqual(expected.count, 7, "every SessionState case is covered")
        for (state, interactive) in expected {
            XCTAssertEqual(
                PaletteOptionsRow.isInteractive(sessionState: state), interactive,
                "isInteractive(\(state.rawValue))")
        }
    }

    // MARK: - Review card (ruling R19)

    /// `.error` keeps Insert, Copy and Start Over, as the old palette did.
    func test_review_card_shows_in_review_error_and_privacy() {
        XCTAssertTrue(CommandPaletteView.showsReviewCard(sessionState: .review, hasPrivacyPreview: false))
        XCTAssertTrue(CommandPaletteView.showsReviewCard(sessionState: .error, hasPrivacyPreview: false))
        XCTAssertTrue(CommandPaletteView.showsReviewCard(sessionState: .idle, hasPrivacyPreview: true))
    }

    func test_idle_shows_the_last_dictation_card() {
        XCTAssertFalse(CommandPaletteView.showsReviewCard(sessionState: .idle, hasPrivacyPreview: false))
        XCTAssertFalse(CommandPaletteView.showsReviewCard(sessionState: .onboarding, hasPrivacyPreview: false))
    }
}
