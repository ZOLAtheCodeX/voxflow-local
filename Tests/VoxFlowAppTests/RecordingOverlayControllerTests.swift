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
/// slow machine cannot make them fail. The two tests that need the timer to
/// fire use 250 ms: short enough to stay fast, long enough that a poll cannot
/// miss the outcome window.
@MainActor
final class RecordingOverlayControllerTests: XCTestCase {

    func testHiddenInitially() {
        let controller = RecordingOverlayController(state: AppState(), outcomeDuration: .zero, onCancel: {})
        XCTAssertFalse(controller.isVisible)
    }

    func testShowsForRecordingAndTranscribingHidesOtherwise() {
        let controller = RecordingOverlayController(state: AppState(), outcomeDuration: .zero, onCancel: {})
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
        let controller = RecordingOverlayController(state: AppState(), outcomeDuration: .zero, onCancel: {})
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.panelForTesting.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.panelForTesting.canBecomeKey)
        controller.sessionStateChanged(.idle)
    }

    // MARK: - Outcome

    /// Long enough that an outcome cannot time out while a test reads it.
    private let holdDuration: Duration = .seconds(30)

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

    func test_successful_insert_shows_inserted_then_hides() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: .milliseconds(250), onCancel: {})
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.lastInsertResult = success()
        controller.sessionStateChanged(.idle)

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown, "no outcome was shown")
        XCTAssertEqual(controller.currentOutcome, .inserted)
        XCTAssertTrue(controller.isVisible, "the outcome lingers on screen")

        let hidden = await waitUntil { !controller.isVisible }
        XCTAssertTrue(hidden, "the outcome never hid")
        XCTAssertNil(controller.currentOutcome)
    }

    /// Review Focus 1: a path that sets `lastInsertResult` just after the
    /// session turns `.idle`, in the same turn, still reads as inserted.
    func test_result_set_just_after_idle_still_counts() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
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
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "Review ready"
        controller.sessionStateChanged(.review)

        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .readyToReview)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.panelForTesting.frame.size, RecordingOverlayController.pillSize(for: .readyToReview))
        finish(controller)
    }

    func test_failed_insert_shows_not_inserted_with_status_line() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
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
        finish(controller)
    }

    /// A cancel or a press too short to count ends the recording without
    /// transcribing: no outcome.
    func test_recording_straight_to_idle_shows_nothing() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.isVisible)
        state.statusLine = "Capture canceled"
        controller.sessionStateChanged(.idle)
        XCTAssertFalse(controller.isVisible)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.currentOutcome)
        XCTAssertFalse(controller.isVisible)
    }

    func test_new_recording_replaces_outcome() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: .milliseconds(250), onCancel: {})
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
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
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
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
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
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
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

    /// An empty-capture reject sets the session idle, then awaits the
    /// backend's speech diagnosis before writing its status line. The
    /// neutral outcome follows the status line, so the pill never keeps
    /// saying "Transcribing..." for a capture that was rejected.
    func test_status_outcome_follows_a_late_status_line() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
        controller.sessionStateChanged(.recording)
        controller.sessionStateChanged(.transcribing)
        state.statusLine = "Transcribing..."
        controller.sessionStateChanged(.idle)
        let shown = await waitUntil { controller.currentOutcome != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.currentOutcome, .status(message: "Transcribing..."))

        state.statusLine = "Speech detected but too quiet (audio kept)"
        XCTAssertEqual(controller.currentOutcome, .status(message: "Speech detected but too quiet (audio kept)"))
        finish(controller)
    }

    /// A failed insert keeps its own message: a later status line (a copy
    /// from the palette, say) does not relabel the warning.
    func test_not_inserted_outcome_keeps_its_message() async {
        let state = AppState()
        let controller = RecordingOverlayController(state: state, outcomeDuration: holdDuration, onCancel: {})
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

    // MARK: - Timer copy

    func test_pill_timer_reads_minutes_and_seconds() {
        XCTAssertEqual(RecordingPillView.elapsedText(0), "0:00")
        XCTAssertEqual(RecordingPillView.elapsedText(7.9), "0:07")
        XCTAssertEqual(RecordingPillView.elapsedText(65), "1:05")
        XCTAssertEqual(RecordingPillView.elapsedText(-3), "0:00")
    }
}
