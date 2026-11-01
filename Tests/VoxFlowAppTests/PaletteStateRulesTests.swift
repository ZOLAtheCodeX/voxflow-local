import XCTest
@testable import VoxFlowApp

/// Which palette controls each session state exposes.
final class PaletteStateRulesTests: XCTestCase {

    // MARK: - Options row (ruling R18)

    /// The options row's menus are disabled while a capture is in flight:
    /// the workflow Mode picker clears candidates and restarts the backend.
    /// (The old palette hid its Cleanup and Tone chips then, but its Skill
    /// profile and Voice actions menus stayed reachable; Settings still
    /// changes those mid-capture.)
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

    // MARK: - Cleanup level menu (ruling R33)

    /// The menu sets the cleanup level of the text the review card shows;
    /// every capture overwrites it. It appears only where it acts.
    func test_cleanup_menu_shows_only_with_the_review_card() {
        XCTAssertTrue(PaletteOptionsRow.showsCleanupMenu(sessionState: .review, hasPrivacyPreview: false))
        XCTAssertTrue(PaletteOptionsRow.showsCleanupMenu(sessionState: .error, hasPrivacyPreview: false))
        XCTAssertTrue(PaletteOptionsRow.showsCleanupMenu(sessionState: .idle, hasPrivacyPreview: true))
        for state: SessionState in [.idle, .recording, .transcribing, .inserting, .onboarding] {
            XCTAssertFalse(
                PaletteOptionsRow.showsCleanupMenu(sessionState: state, hasPrivacyPreview: false),
                "showsCleanupMenu(\(state.rawValue))")
        }
    }

    /// "Cleanup level", so it is not read as the footer's "Cleanup:" engine.
    func test_cleanup_menu_title_names_the_level() {
        XCTAssertEqual(PaletteOptionsRow.cleanupMenuTitle(.raw), "Cleanup level: Raw")
        XCTAssertEqual(PaletteOptionsRow.cleanupMenuTitle(.light), "Cleanup level: Light")
        XCTAssertEqual(PaletteOptionsRow.cleanupMenuTitle(.polish), "Cleanup level: Polish")
    }

    // MARK: - Progress card (M1)

    /// A review insert (.review to .inserting) shows the Insert stage, not
    /// Transcribe; while transcribing, the stage still follows elapsed time.
    func test_progress_card_shows_the_insert_stage_while_inserting() {
        XCTAssertEqual(PaletteProgressCard.stage(sessionState: .inserting, elapsedSeconds: 0), .inserting)
        XCTAssertEqual(PaletteProgressCard.stage(sessionState: .inserting, elapsedSeconds: 9), .inserting)
        XCTAssertEqual(PaletteProgressCard.stage(sessionState: .transcribing, elapsedSeconds: 0), .transcribing)
        XCTAssertEqual(PaletteProgressCard.stage(sessionState: .transcribing, elapsedSeconds: 3), .transcribing)
        XCTAssertEqual(PaletteProgressCard.stage(sessionState: .transcribing, elapsedSeconds: 4), .cleaning)
    }

    // MARK: - Current result in idle (ruling R36)

    /// Translate, meeting and prompt results never enter the recent
    /// dictations, so after an insert their review card stays up in idle, as
    /// in the old palette, but without the return and Cmd-R keys (R13).
    func test_idle_non_dictation_result_keeps_its_review_card_without_keys() {
        for mode: WorkflowMode in [.translateEnToDe, .meeting, .prompt] {
            XCTAssertEqual(
                CommandPaletteView.dictateCardKind(
                    sessionState: .idle, hasPrivacyPreview: false, workflowMode: mode, displayText: "Ergebnis"),
                .review(bindsKeys: false), mode.rawValue)
            XCTAssertEqual(
                CommandPaletteView.dictateCardKind(
                    sessionState: .idle, hasPrivacyPreview: false, workflowMode: mode, displayText: ""),
                .lastDictation, "\(mode.rawValue) with no result")
        }
    }

    /// Dictation keeps the Last-dictation card in idle; its Insert Again
    /// falls back to the current result instead.
    func test_idle_dictation_shows_the_last_dictation_card() {
        XCTAssertEqual(
            CommandPaletteView.dictateCardKind(
                sessionState: .idle, hasPrivacyPreview: false, workflowMode: .dictation, displayText: "Draft."),
            .lastDictation)
    }

    func test_review_states_bind_the_keys() {
        for mode in WorkflowMode.allCases {
            XCTAssertEqual(
                CommandPaletteView.dictateCardKind(
                    sessionState: .review, hasPrivacyPreview: false, workflowMode: mode, displayText: "x"),
                .review(bindsKeys: true))
            XCTAssertEqual(
                CommandPaletteView.dictateCardKind(
                    sessionState: .error, hasPrivacyPreview: false, workflowMode: mode, displayText: ""),
                .review(bindsKeys: true))
            XCTAssertEqual(
                CommandPaletteView.dictateCardKind(
                    sessionState: .idle, hasPrivacyPreview: true, workflowMode: mode, displayText: "x"),
                .review(bindsKeys: true))
        }
        XCTAssertEqual(
            CommandPaletteView.dictateCardKind(
                sessionState: .onboarding, hasPrivacyPreview: false, workflowMode: .meeting, displayText: "x"),
            .lastDictation)
    }
}
