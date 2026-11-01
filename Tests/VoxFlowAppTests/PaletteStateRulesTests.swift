import XCTest
@testable import VoxFlowApp

/// Which palette controls each session state exposes.
final class PaletteStateRulesTests: XCTestCase {

    // MARK: - Options row (ruling R38, superseding R18's whole-row rule)

    private let allStates: [SessionState] = [.idle, .recording, .transcribing, .review, .inserting, .onboarding, .error]

    /// While a capture is in flight the configuration controls are disabled:
    /// the workflow Mode picker clears candidates and restarts the backend.
    func test_configuration_controls_are_disabled_during_a_capture() {
        let capturing: Set<SessionState> = [.recording, .transcribing, .inserting]
        let configuration: [PaletteOptionsRow.Option] = [.cleanupLevel, .tone, .appProfile, .provider, .mode, .setup]
        for option in configuration {
            for state in allStates {
                XCTAssertEqual(
                    PaletteOptionsRow.isEnabled(option, sessionState: state), !capturing.contains(state),
                    "\(option) in \(state.rawValue)")
            }
        }
    }

    /// Changing the skill profile or the voice-action mode revokes captured
    /// permissions and a pending Enter, so both stay reachable mid-capture,
    /// as they were in the old palette.
    func test_revocation_menus_stay_enabled_in_every_state() {
        for option: PaletteOptionsRow.Option in [.skillProfile, .voiceActions] {
            for state in allStates {
                XCTAssertTrue(PaletteOptionsRow.isEnabled(option, sessionState: state), "\(option) in \(state.rawValue)")
            }
        }
    }

    func test_every_option_has_a_rule() {
        XCTAssertEqual(PaletteOptionsRow.Option.allCases.count, 8)
        XCTAssertEqual(allStates.count, 7, "every SessionState case is covered")
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
