import XCTest
@testable import VoxFlowApp

/// R4.1: the floating recording pill. All recording feedback previously
/// lived inside the 430 px menu bar panel — while dictating into another
/// app there was zero on-screen feedback beyond the status-bar symbol.
///
/// The UI refresh adds an outcome state after a capture. The original tests
/// use `outcomeDuration: .zero` (no outcome) so they keep their meaning. The
/// outcome tests wait by polling with generous deadlines instead of fixed
/// sleeps, and use a 30 s duration wherever they only read the outcome, so a
/// slow machine cannot make them fail. The tests that need a timer to fire
/// use a few hundred milliseconds: short enough to stay fast, long enough
/// that a poll cannot miss the window.
///
/// Every controller is built by `makeController`, which records
/// announcements instead of posting them to VoiceOver and, at teardown,
/// cancels any outcome still running, so a failed assertion never leaves a
/// 30 s task or a visible panel behind.
@MainActor
final class RecordingOverlayControllerTests: XCTestCase {

    /// What the controller would have announced, in order.
    @MainActor
    private final class AnnouncementRecorder {
        var messages: [String] = []
    }

    /// Long enough that an outcome cannot time out while a test reads it.
    private let holdDuration: Duration = .seconds(30)

    private func makeController(
        _ state: AppState = AppState(),
        outcomeDuration: Duration,
        lateStatusHold: Duration = .seconds(30),
        recorder: AnnouncementRecorder = AnnouncementRecorder()
    ) -> RecordingOverlayController {
        let controller = RecordingOverlayController(
            state: state, outcomeDuration: outcomeDuration, lateStatusHold: lateStatusHold,
            onCancel: {}, announce: { recorder.messages.append($0) })
        addTeardownBlock { @MainActor in
            // A new capture cancels every outcome task; ending it without
            // transcribing hides the panel.
            controller.sessionStateChanged(.recording)
            controller.sessionStateChanged(.idle)
        }
        return controller
    }

    func testHiddenInitially() {
        let controller = makeController(outcomeDuration: .zero)
        XCTAssertFalse(controller.isVisible)
    }

    func testShowsForRecordingAndTranscribingHidesOtherwise() {
        let controller = makeController(outcomeDuration: .zero)
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.isVisible)
        controller.sessionStateChanged(.transcribing)
        XCTAssertTrue(controller.isVisible)
        controller.sessionStateChanged(.review)
        XCTAssertFalse(controller.isVisible)
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.isVisible)
        controller.sessionStateChanged(.idle)
        XCTAssertFalse(controller.isVisible)
    }

    func testPillPositionIsTopCenterBelowMenuBar() {
        // Pure geometry: pill centered horizontally, 12 pt below the menu bar.
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944) // menu bar = 38 pt
        let pill = NSSize(width: 280, height: 60)
        let origin = RecordingOverlayController.pillOrigin(screenFrame: screen, visibleFrame: visible, pillSize: pill)
        XCTAssertEqual(origin.x, (1512 - 280) / 2, accuracy: 0.5)
        // Cocoa origin is bottom-left: top of pill should sit 12 pt below the
        // visible-frame top (944), so origin.y = 944 - 12 - 60.
        XCTAssertEqual(origin.y, 944 - 12 - 60, accuracy: 0.5)
    }

    func testPanelNeverActivatesOrStealsKey() {
        let controller = makeController(outcomeDuration: .zero)
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.panelForTesting.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.panelForTesting.canBecomeKey)
        controller.sessionStateChanged(.idle)
    }

    // MARK: - Outcome

    private func success() -> InsertResult {
        InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
    }

    private func failure() -> InsertResult {
        InsertResult(method: .failed, success: false, fallbackUsed: false, errorCode: "ax_failed")
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// Ends a test with the panel hidden and the outcome timer cancelled.
    private func finish(_ controller: RecordingOverlayController) {
        controller.sessionStateChanged(.idle)
        XCTAssertFalse(controller.isVisible)
    }

    /// The coordinator's order on a quick dictation: the session turns
    /// `.transcribing`, then the status line says so in the same step, then
    /// the pipeline runs on later turns. Returns once the controller has read
    /// that line as the one current at `.transcribing` entry.
    private func enterTranscribing(
        _ controller: RecordingOverlayController, _ state: AppState, line: String = "Transcribing..."
    ) async {
        state.statusLine = "Listening... release hotkey to transcribe"
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = line
        let recorded = await waitUntil { controller.transcribingLineForTesting == line }
        XCTAssertTrue(recorded, "the controller never read the line written at .transcribing entry")
    }

    func test_successful_insert_shows_inserted_then_hides() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: .milliseconds(250), recorder: recorder)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.lastInsertResult = success()
        controller.sessionStateChanged(.idle)

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown, "no outcome was shown")
        XCTAssertEqual(controller.currentOutcome, .inserted)
        XCTAssertTrue(controller.isVisible, "the outcome lingers on screen")
        XCTAssertEqual(recorder.messages, ["Inserted"])

        let hidden = await waitUntil { !controller.isVisible }
        XCTAssertTrue(hidden, "the outcome never hid")
        XCTAssertNil(controller.currentOutcome)
    }

    /// Review Focus 1: a path that sets `lastInsertResult` just after the
    /// session turns `.idle`, in the same turn, still reads as inserted.
    func test_result_set_just_after_idle_still_counts() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        controller.sessionStateChanged(.idle)
        state.lastInsertResult = success()

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .inserted)
        finish(controller)
    }

    func test_review_shows_ready_to_review() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "Review ready"
        controller.sessionStateChanged(.review)

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .readyToReview)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.panelForTesting.frame.size, RecordingOverlayController.pillSize(for: .readyToReview))
        XCTAssertEqual(recorder.messages, ["Ready to review"])
        finish(controller)
    }

    func test_failed_insert_shows_not_inserted_with_status_line() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.lastInsertResult = failure()
        state.statusLine = "Insert failed. Copied to clipboard."
        controller.sessionStateChanged(.review)

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        // A failure wins over review.
        XCTAssertEqual(controller.currentOutcome, .notInserted(message: "Insert failed. Copied to clipboard."))
        XCTAssertEqual(controller.panelForTesting.frame.size, NSSize(width: 360, height: 32))
        XCTAssertEqual(recorder.messages, ["Not inserted. Insert failed. Copied to clipboard."])
        finish(controller)
    }

    /// `handleCaptureError` sets `.error`, then the status line, in the same
    /// turn. The pill reports a failure, not neutral information.
    func test_error_ending_shows_not_inserted() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        controller.sessionStateChanged(.error)
        state.statusLine = "Error. Retry capture."

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .notInserted(message: "Error. Retry capture."))
        XCTAssertEqual(controller.panelForTesting.frame.size, NSSize(width: 360, height: 32))
        XCTAssertEqual(recorder.messages, ["Not inserted. Error. Retry capture."])
        finish(controller)
    }

    /// A cancel while recording ends the capture without transcribing: no
    /// outcome. (A press too short to count does pass through
    /// `.transcribing`; see `test_too_short_press_shows_its_status_line`.)
    func test_recording_straight_to_idle_shows_nothing() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.isVisible)
        state.statusLine = "Capture canceled"
        controller.sessionStateChanged(.idle)
        XCTAssertFalse(controller.isVisible)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.currentOutcome)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(recorder.messages, [])
    }

    /// Ruling R10: `stopAndValidateAudio` sets `.idle`, then "Too short",
    /// in the same turn, after the session entered `.transcribing`. The pill
    /// shows that line as neutral information.
    func test_too_short_press_shows_its_status_line() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        await enterTranscribing(controller, state)
        controller.sessionStateChanged(.idle)
        state.statusLine = "Too short — hold longer to dictate"

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .status(message: "Too short — hold longer to dictate"))
        XCTAssertFalse(controller.isHoldingForStatusLine)
        XCTAssertEqual(recorder.messages, ["Too short — hold longer to dictate"])
        finish(controller)
    }

    func test_new_recording_replaces_outcome() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: .milliseconds(250))
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "No speech detected"
        controller.sessionStateChanged(.idle)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)

        controller.sessionStateChanged(.recording)
        XCTAssertNil(controller.currentOutcome, "a new capture replaces the outcome at once")
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.panelForTesting.frame.size, RecordingOverlayController.pillSize(for: nil))

        // The old outcome's timer must not hide the new capture's pill.
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(controller.isVisible)
        XCTAssertNil(controller.currentOutcome)
        finish(controller)
    }

    func test_outcome_passes_mouse_events_through() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration)
        controller.sessionStateChanged(.recording)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents, "the live pill takes clicks (cancel)")
        controller.sessionStateChanged(.transcribing)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents)
        state.lastInsertResult = success()
        controller.sessionStateChanged(.idle)

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertTrue(controller.panelForTesting.ignoresMouseEvents, "the outcome is click-through")

        controller.sessionStateChanged(.recording)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents)
        finish(controller)
    }

    /// Inserting from the palette's review is not a capture: no pill.
    func test_review_insert_without_capture_stays_hidden() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration)
        controller.sessionStateChanged(.inserting)
        XCTAssertFalse(controller.isVisible)
        state.lastInsertResult = success()
        state.statusLine = "Inserted"
        controller.sessionStateChanged(.idle)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.currentOutcome)
        XCTAssertFalse(controller.isVisible)
    }

    /// After a capture ends in review and its outcome is classified, inserting
    /// from review is a separate step and must not reuse the capture's pill.
    func test_review_insert_after_capture_outcome_hides() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        controller.sessionStateChanged(.review)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)

        controller.sessionStateChanged(.inserting)
        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(controller.currentOutcome)
        state.lastInsertResult = success()
        controller.sessionStateChanged(.idle)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.currentOutcome)
        XCTAssertFalse(controller.isVisible)
    }

    /// A failed insert keeps its own message: a later status line (a copy
    /// from the palette, say) does not relabel the warning.
    func test_not_inserted_outcome_keeps_its_message() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.lastInsertResult = failure()
        state.statusLine = "Insert failed. Copied to clipboard."
        controller.sessionStateChanged(.review)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)

        state.statusLine = "Copied to clipboard"
        XCTAssertEqual(controller.currentOutcome, .notInserted(message: "Insert failed. Copied to clipboard."))
        finish(controller)
    }

    // MARK: - Late status lines (ruling R29)

    /// An empty-capture reject sets the session idle, then awaits the
    /// backend's speech diagnosis before writing its reason, so the
    /// classifier still sees "Transcribing...". The pill keeps the working
    /// row instead of showing that line, and the late reason gets a full
    /// outcome window of its own: the hold's timer no longer runs.
    func test_late_reason_after_transcribing_line_gets_a_full_outcome_window() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(
            state, outcomeDuration: holdDuration, lateStatusHold: .milliseconds(400), recorder: recorder)
        await enterTranscribing(controller, state)
        controller.sessionStateChanged(.idle)

        let holding = await waitUntil { controller.isHoldingForStatusLine }
        XCTAssertTrue(holding, "the transcribing-era line was shown as the outcome")
        XCTAssertNil(controller.currentOutcome, "no outcome while waiting for the reason")
        XCTAssertTrue(controller.isVisible, "the working row stays up while waiting")
        XCTAssertEqual(recorder.messages, [], "nothing is announced while waiting")

        let reason = "Speech detected but too quiet (audio kept)"
        state.statusLine = reason
        XCTAssertEqual(controller.currentOutcome, .status(message: reason))
        XCTAssertFalse(controller.isHoldingForStatusLine)
        XCTAssertEqual(controller.panelForTesting.frame.size, RecordingOverlayController.pillSize(for: .status(message: reason)))
        XCTAssertEqual(recorder.messages, [reason])

        // Well past the hold: the reason is still up, on its own 30 s window.
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(controller.currentOutcome, .status(message: reason))
        XCTAssertTrue(controller.isVisible)
        finish(controller)
    }

    /// After the late reason, nothing else replaces it: not a focus change's
    /// "Ready in X" line, not anything later.
    func test_second_late_status_line_does_not_replace_the_reason() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        await enterTranscribing(controller, state)
        controller.sessionStateChanged(.idle)
        let holding = await waitUntil { controller.isHoldingForStatusLine }
        XCTAssertTrue(holding)

        let reason = "Background noise only (audio kept)"
        state.statusLine = reason
        state.statusLine = "Ready in Notes. Hold hotkey to talk"
        state.statusLine = "Hold hotkey to talk"
        XCTAssertEqual(controller.currentOutcome, .status(message: reason))
        XCTAssertEqual(recorder.messages, [reason])
        finish(controller)
    }

    /// No new status line within the hold: the pill hides with no outcome
    /// rather than call "Transcribing..." the result.
    func test_no_status_change_within_the_hold_hides_without_an_outcome() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(
            state, outcomeDuration: holdDuration, lateStatusHold: .milliseconds(200), recorder: recorder)
        await enterTranscribing(controller, state)
        controller.sessionStateChanged(.idle)
        let holding = await waitUntil { controller.isHoldingForStatusLine }
        XCTAssertTrue(holding)

        let hidden = await waitUntil { !controller.isVisible }
        XCTAssertTrue(hidden, "the hold never ended")
        XCTAssertNil(controller.currentOutcome)
        XCTAssertFalse(controller.isHoldingForStatusLine)
        XCTAssertEqual(recorder.messages, [])

        // A line written after the hold ended shows nothing.
        state.statusLine = "Speech detected but too quiet (audio kept)"
        XCTAssertNil(controller.currentOutcome)
        XCTAssertFalse(controller.isVisible)
    }

    /// A new capture during the hold cancels it at once.
    func test_new_recording_cancels_the_hold() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration, lateStatusHold: .milliseconds(200))
        await enterTranscribing(controller, state)
        controller.sessionStateChanged(.idle)
        let holding = await waitUntil { controller.isHoldingForStatusLine }
        XCTAssertTrue(holding)

        controller.sessionStateChanged(.recording)
        XCTAssertFalse(controller.isHoldingForStatusLine)
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents, "the live pill takes clicks again")

        // The old hold's timer must not hide the new capture's pill, and a
        // late line from the old capture must not become its outcome.
        try? await Task.sleep(for: .milliseconds(500))
        state.statusLine = "Background noise only (audio kept)"
        XCTAssertTrue(controller.isVisible)
        XCTAssertNil(controller.currentOutcome)
        finish(controller)
    }

    /// Outside the hold, a shown status outcome follows exactly one later
    /// status line (it IS the status line), and only that one.
    func test_status_outcome_follows_one_later_status_line() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "Unknown command: lunch"
        controller.sessionStateChanged(.idle)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .status(message: "Unknown command: lunch"))

        state.statusLine = "Speech detected but too quiet (audio kept)"
        XCTAssertEqual(controller.currentOutcome, .status(message: "Speech detected but too quiet (audio kept)"))
        state.statusLine = "Ready in Notes. Hold hotkey to talk"
        XCTAssertEqual(controller.currentOutcome, .status(message: "Speech detected but too quiet (audio kept)"))
        XCTAssertEqual(recorder.messages, ["Unknown command: lunch", "Speech detected but too quiet (audio kept)"])
        finish(controller)
    }

    /// The one follow restarts the hide timer, so the corrected line gets a
    /// full window rather than what was left of the first one.
    func test_follow_restarts_the_hide_timer() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: .milliseconds(1000))
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "No speech detected"
        controller.sessionStateChanged(.idle)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)

        try? await Task.sleep(for: .milliseconds(600))
        guard controller.currentOutcome != nil else {
            return XCTFail("the first window ended before the follow; the machine is too slow for this test")
        }
        state.statusLine = "Speech detected but not recognized (audio kept)"

        // 1.1 s after the first outcome, 0.5 s after the follow: the first
        // window has ended, the restarted one has not.
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.currentOutcome, .status(message: "Speech detected but not recognized (audio kept)"))
        XCTAssertTrue(controller.isVisible)

        let hidden = await waitUntil { !controller.isVisible }
        XCTAssertTrue(hidden, "the restarted window never ended")
    }

    // MARK: - Focus-change status lines (ruling R35)

    private func focus(_ appName: String) -> FocusTargetSnapshot {
        FocusTargetSnapshot(
            hasFocusedTextInput: true, hasInsertionCursor: true, appName: appName,
            bundleID: "com.example.\(appName.lowercased())", role: "AXTextArea", processIdentifier: nil)
    }

    /// `AppCoordinator.startFocusMonitoring` publishes `focusTarget`, then
    /// writes its "Ready in X" line in the same turn. That line neither ends
    /// the hold nor becomes the outcome; the reject reason that follows on a
    /// later turn does.
    func test_focus_line_during_the_hold_does_not_end_it() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        await enterTranscribing(controller, state)
        controller.sessionStateChanged(.idle)
        let holding = await waitUntil { controller.isHoldingForStatusLine }
        XCTAssertTrue(holding)

        state.focusTarget = focus("Mail")
        state.statusLine = "Ready in Mail. Hold hotkey to talk"
        XCTAssertTrue(controller.isHoldingForStatusLine, "a focus line ended the hold")
        XCTAssertNil(controller.currentOutcome)

        try? await Task.sleep(for: .milliseconds(20))
        let reason = "Speech detected but too quiet (audio kept)"
        state.statusLine = reason
        XCTAssertEqual(controller.currentOutcome, .status(message: reason))
        XCTAssertEqual(recorder.messages, [reason])
        finish(controller)
    }

    /// After a shown outcome a focus line neither replaces it nor uses up the
    /// one follow: a later capture line on a later turn still corrects it.
    func test_focus_line_does_not_replace_or_consume_the_follow() async {
        let state = AppState()
        let recorder = AnnouncementRecorder()
        let controller = makeController(state, outcomeDuration: holdDuration, recorder: recorder)
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "No speech detected"
        controller.sessionStateChanged(.idle)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)

        state.focusTarget = focus("Mail")
        state.statusLine = "Ready in Mail. Hold hotkey to talk"
        XCTAssertEqual(controller.currentOutcome, .status(message: "No speech detected"))

        try? await Task.sleep(for: .milliseconds(20))
        state.statusLine = "Speech detected but not recognized (audio kept)"
        XCTAssertEqual(controller.currentOutcome, .status(message: "Speech detected but not recognized (audio kept)"))
        XCTAssertEqual(recorder.messages, ["No speech detected", "Speech detected but not recognized (audio kept)"])
        finish(controller)
    }

    /// Only the turn of the focus change is ignored.
    func test_a_focus_change_on_an_earlier_turn_does_not_mute_later_lines() async {
        let state = AppState()
        let controller = makeController(state, outcomeDuration: holdDuration)
        await enterTranscribing(controller, state)
        state.focusTarget = focus("Mail")
        controller.sessionStateChanged(.idle)
        let holding = await waitUntil { controller.isHoldingForStatusLine }
        XCTAssertTrue(holding)

        state.statusLine = "Background noise only (audio kept)"
        XCTAssertEqual(controller.currentOutcome, .status(message: "Background noise only (audio kept)"))
        finish(controller)
    }

    // MARK: - Click-through (ruling R45)

    /// The pill takes clicks only while it offers cancel; while inserting it
    /// offers none, so clicks pass through to the app underneath.
    func test_pill_passes_clicks_through_while_inserting() {
        let controller = makeController(outcomeDuration: .zero)
        controller.sessionStateChanged(.recording)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents)
        controller.sessionStateChanged(.transcribing)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents)
        controller.sessionStateChanged(.inserting)
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.panelForTesting.ignoresMouseEvents, "no cancel while inserting: click-through")
        controller.sessionStateChanged(.recording)
        XCTAssertFalse(controller.panelForTesting.ignoresMouseEvents, "a new capture takes clicks again")
        controller.sessionStateChanged(.idle)
    }

    // MARK: - Timer copy

    func test_pill_timer_reads_minutes_and_seconds() {
        XCTAssertEqual(RecordingPillView.elapsedText(0), "0:00")
        XCTAssertEqual(RecordingPillView.elapsedText(7.9), "0:07")
        XCTAssertEqual(RecordingPillView.elapsedText(65), "1:05")
        XCTAssertEqual(RecordingPillView.elapsedText(-3), "0:00")
    }

    // MARK: - Cancel reach (ruling R31)

    /// The hover × and the VoiceOver "Cancel dictation" action share one
    /// rule: a recording or a transcription can be canceled; an insert in
    /// progress, an outcome and the late-status hold cannot.
    func test_cancel_is_offered_while_recording_or_transcribing_only() {
        XCTAssertTrue(RecordingPillView.offersCancel(sessionState: .recording))
        XCTAssertTrue(RecordingPillView.offersCancel(sessionState: .transcribing))
        XCTAssertFalse(RecordingPillView.offersCancel(sessionState: .inserting))
        XCTAssertFalse(RecordingPillView.offersCancel(sessionState: .idle))
        XCTAssertFalse(RecordingPillView.offersCancel(sessionState: .review))
        XCTAssertFalse(RecordingPillView.offersCancel(sessionState: .error))
        XCTAssertFalse(RecordingPillView.offersCancel(sessionState: .onboarding))
    }
}
